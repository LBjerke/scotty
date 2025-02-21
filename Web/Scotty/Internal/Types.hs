{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# language ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}
module Web.Scotty.Internal.Types where

import           Blaze.ByteString.Builder (Builder)

import           Control.Applicative
import Control.Concurrent.MVar
import Control.Concurrent.STM (TVar, atomically, readTVarIO, modifyTVar')
import qualified Control.Exception as E
import           Control.Monad (MonadPlus(..))
import           Control.Monad.Base (MonadBase)
import           Control.Monad.Catch (MonadCatch, MonadThrow)
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.IO.Class (MonadIO(..))
import UnliftIO (MonadUnliftIO(..))
import           Control.Monad.Reader (MonadReader(..), ReaderT, asks)
import           Control.Monad.State.Strict (State, StateT(..))
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.Control (MonadBaseControl, MonadTransControl)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS8 (ByteString)
import           Data.Default.Class (Default, def)
import           Data.String (IsString(..))
import           Data.Text.Lazy (Text, pack)
import           Data.Typeable (Typeable)

import           Network.HTTP.Types

import           Network.Wai hiding (Middleware, Application)
import qualified Network.Wai as Wai
import           Network.Wai.Handler.Warp (Settings, defaultSettings)
import           Network.Wai.Parse (FileInfo)

import Web.Scotty.Exceptions (Handler(..), catch, catches)


--------------------- Options -----------------------
data Options = Options { verbose :: Int -- ^ 0 = silent, 1(def) = startup banner
                       , settings :: Settings -- ^ Warp 'Settings'
                                              -- Note: to work around an issue in warp,
                                              -- the default FD cache duration is set to 0
                                              -- so changes to static files are always picked
                                              -- up. This likely has performance implications,
                                              -- so you may want to modify this for production
                                              -- servers using `setFdCacheDuration`.
                       }

instance Default Options where
  def = defaultOptions

defaultOptions :: Options
defaultOptions = Options 1 defaultSettings

newtype RouteOptions = RouteOptions { maxRequestBodySize :: Maybe Kilobytes -- max allowed request size in KB
                                    }

instance Default RouteOptions where
    def = defaultRouteOptions

defaultRouteOptions :: RouteOptions
defaultRouteOptions = RouteOptions Nothing

type Kilobytes = Int
----- Transformer Aware Applications/Middleware -----
type Middleware m = Application m -> Application m
type Application m = Request -> m Response

------------------ Scotty Request Body --------------------

data BodyChunkBuffer = BodyChunkBuffer { hasFinishedReadingChunks :: Bool -- ^ whether we've reached the end of the stream yet
                                       , chunksReadSoFar :: [BS.ByteString]
                                       }
-- | The key part of having two MVars is that we can "clone" the BodyInfo to create a copy where the index is reset to 0, but the chunk cache is the same. Passing a cloned BodyInfo into each matched route allows them each to start from the first chunk if they call bodyReader.
--
-- Introduced in (#308)
data BodyInfo = BodyInfo { bodyInfoReadProgress :: MVar Int -- ^ index into the stream read so far
                         , bodyInfoChunkBuffer :: MVar BodyChunkBuffer
                         , bodyInfoDirectChunkRead :: IO BS.ByteString -- ^ can be called to get more chunks
                         }

--------------- Scotty Applications -----------------

data ScottyState m =
    ScottyState { middlewares :: [Wai.Middleware]
                , routes :: [BodyInfo -> Middleware m]
                , handler :: Maybe (ErrorHandler m)
                , routeOptions :: RouteOptions
                }

instance Default (ScottyState m) where
  def = defaultScottyState

defaultScottyState :: ScottyState m
defaultScottyState = ScottyState [] [] Nothing defaultRouteOptions

addMiddleware :: Wai.Middleware -> ScottyState m -> ScottyState m
addMiddleware m s@(ScottyState {middlewares = ms}) = s { middlewares = m:ms }

addRoute :: (BodyInfo -> Middleware m) -> ScottyState m -> ScottyState m
addRoute r s@(ScottyState {routes = rs}) = s { routes = r:rs }

setHandler :: Maybe (ErrorHandler m) -> ScottyState m -> ScottyState m
setHandler h s = s { handler = h }

updateMaxRequestBodySize :: RouteOptions -> ScottyState m -> ScottyState m
updateMaxRequestBodySize RouteOptions { .. } s@ScottyState { routeOptions = ro } =
    let ro' = ro { maxRequestBodySize = maxRequestBodySize }
    in s { routeOptions = ro' }

newtype ScottyT m a = ScottyT { runS :: State (ScottyState m) a }
    deriving ( Functor, Applicative, Monad )


------------------ Scotty Errors --------------------

-- | Internal exception mechanism used to modify the request processing flow.
--
-- The exception constructor is not exposed to the user and all exceptions of this type are caught
-- and processed within the 'runAction' function.
data ActionError
  = AERedirect Text -- ^ Redirect
  | AENext -- ^ Stop processing this route and skip to the next one
  | AEFinish -- ^ Stop processing the request
  deriving (Show, Typeable)
instance E.Exception ActionError

tryNext :: MonadUnliftIO m => m a -> m Bool
tryNext io = catch (io >> pure True) $ \e ->
  case e of
    AENext -> pure False
    _ -> pure True

-- | E.g. when a parameter is not found in a query string (400 Bad Request) or when parsing a JSON body fails (422 Unprocessable Entity)
data StatusError = StatusError Status Text deriving (Show, Typeable)
instance E.Exception StatusError

-- | Specializes a 'Handler' to the 'ActionT' monad
type ErrorHandler m = Handler (ActionT m) ()

-- | Thrown e.g. when a request is too large
data ScottyException = RequestException BS.ByteString Status deriving (Show, Typeable)
instance E.Exception ScottyException

------------------ Scotty Actions -------------------
type Param = (Text, Text)

type File = (Text, FileInfo LBS8.ByteString)

data ActionEnv = Env { envReq       :: Request
                     , envCaptureParams :: [Param]
                     , envFormParams    :: [Param]
                     , envQueryParams :: [Param]
                     , envBody      :: IO LBS8.ByteString
                     , envBodyChunk :: IO BS.ByteString
                     , envFiles     :: [File]
                     , envResponse :: TVar ScottyResponse
                     }

getResponse :: MonadIO m => ActionEnv -> m ScottyResponse
getResponse ae = liftIO $ readTVarIO (envResponse ae)

getResponseAction :: (MonadIO m) => ActionT m ScottyResponse
getResponseAction = do
  ae <- ask
  getResponse ae

modifyResponse :: (MonadIO m) => (ScottyResponse -> ScottyResponse) -> ActionT m ()
modifyResponse f = do
  tv <- asks envResponse
  liftIO $ atomically $ modifyTVar' tv f

data BodyPartiallyStreamed = BodyPartiallyStreamed deriving (Show, Typeable)

instance E.Exception BodyPartiallyStreamed

data Content = ContentBuilder  Builder
             | ContentFile     FilePath
             | ContentStream   StreamingBody
             | ContentResponse Response

data ScottyResponse = SR { srStatus  :: Status
                         , srHeaders :: ResponseHeaders
                         , srContent :: Content
                         }

setContent :: Content -> ScottyResponse -> ScottyResponse
setContent c sr = sr { srContent = c }

setHeaderWith :: ([(HeaderName, BS.ByteString)] -> [(HeaderName, BS.ByteString)]) -> ScottyResponse -> ScottyResponse
setHeaderWith f sr = sr { srHeaders = f (srHeaders sr) }

setStatus :: Status -> ScottyResponse -> ScottyResponse
setStatus s sr = sr { srStatus = s }

instance Default ScottyResponse where
  def = defaultScottyResponse

-- | The default response has code 200 OK and empty body
defaultScottyResponse :: ScottyResponse
defaultScottyResponse = SR status200 [] (ContentBuilder mempty)


newtype ActionT m a = ActionT { runAM :: ReaderT ActionEnv m a }
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader ActionEnv, MonadTrans, MonadThrow, MonadCatch, MonadBase b, MonadBaseControl b, MonadTransControl, MonadUnliftIO)

-- | Models the invariant that only 'StatusError's can be thrown and caught.
instance (MonadUnliftIO m) => MonadError StatusError (ActionT m) where
  throwError = E.throw
  catchError = catch
-- | Modeled after the behaviour in scotty < 0.20, 'fail' throws a 'StatusError' with code 500 ("Server Error"), which can be caught with 'E.catch' or 'rescue'.
instance (MonadIO m) => MonadFail (ActionT m) where
  fail = E.throw . StatusError status500 . pack
-- | 'empty' throws 'ActionError' 'AENext', whereas '(<|>)' catches any 'ActionError's or 'StatusError's in the first action and proceeds to the second one.
instance (MonadUnliftIO m) => Alternative (ActionT m) where
  empty = E.throw AENext
  a <|> b = do
    ok <- tryAnyStatus a
    if ok then a else b
instance (MonadUnliftIO m) => MonadPlus (ActionT m) where
  mzero = empty
  mplus = (<|>)

-- | catches either ActionError (thrown by 'next') or 'StatusError' (thrown if e.g. a query parameter is not found)
tryAnyStatus :: MonadUnliftIO m => m a -> m Bool
tryAnyStatus io = (io >> pure True) `catches` [h1, h2]
  where
    h1 = Handler $ \(_ :: ActionError) -> pure False
    h2 = Handler $ \(_ :: StatusError) -> pure False

instance (Semigroup a) => Semigroup (ScottyT m a) where
  x <> y = (<>) <$> x <*> y

instance
  ( Monoid a
#if !(MIN_VERSION_base(4,11,0))
  , Semigroup a
#endif
#if !(MIN_VERSION_base(4,8,0))
  , Functor m
#endif
  ) => Monoid (ScottyT m a) where
  mempty = return mempty
#if !(MIN_VERSION_base(4,11,0))
  mappend = (<>)
#endif

instance
  ( Monad m
#if !(MIN_VERSION_base(4,8,0))
  , Functor m
#endif
  , Semigroup a
  ) => Semigroup (ActionT m a) where
  x <> y = (<>) <$> x <*> y

instance
  ( Monad m, Monoid a
#if !(MIN_VERSION_base(4,11,0))
  , Semigroup a
#endif
#if !(MIN_VERSION_base(4,8,0))
  , Functor m
#endif
  ) => Monoid (ActionT m a) where
  mempty = return mempty
#if !(MIN_VERSION_base(4,11,0))
  mappend = (<>)
#endif

------------------ Scotty Routes --------------------
data RoutePattern = Capture   Text
                  | Literal   Text
                  | Function  (Request -> Maybe [Param])

instance IsString RoutePattern where
    fromString = Capture . pack


