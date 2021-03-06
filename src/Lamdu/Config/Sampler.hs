{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Config.Sampler
    ( Sampler, new, setSelection
    , FiledConfig(..), primaryPath, dependencyPaths, fileData
        , filePaths, sampleFilePaths
    , SampleData(..), sConfig, sTheme, sLanguage
    , Sample(..), sData
    , sConfigData, sThemeData, sLanguageData
    , getSample
    ) where

import           Control.Concurrent.Extended (ThreadId, threadDelay, forkIOUnmasked)
import           Control.Concurrent.MVar
import qualified Control.Exception as E
import qualified Control.Lens as Lens
import qualified Control.Monad.Trans.FastWriter as Writer
import           Data.Aeson (FromJSON)
import qualified Data.Aeson.Config as AesonConfig
import qualified Data.Text as Text
import           Data.Time.Clock (UTCTime)
import           Lamdu.Config (Config)
import           Lamdu.Config.Folder (HasConfigFolder(..), Selection(..))
import           Lamdu.Config.Theme (Theme)
import           Lamdu.I18N.Texts (Language)
import qualified Lamdu.Paths as Paths
import           System.Directory (getModificationTime)
import           System.FilePath (takeDirectory, takeFileName, dropExtension, (</>))

import           Lamdu.Prelude

type ModificationTime = UTCTime

-- TODO: FRP-style sampling of (mtime, file content) of the config
-- file, then map over that to Config

data FiledConfig a = FiledConfig
    { _primaryPath :: FilePath
    , _dependencyPaths :: ![FilePath]
    , _fileData :: !a
    } deriving (Eq)
Lens.makeLenses ''FiledConfig

data SampleData = SampleData
    { _sConfig :: FiledConfig Config
    , _sTheme :: FiledConfig Theme
    , _sLanguage :: FiledConfig Language
    } deriving (Eq)
Lens.makeLenses ''SampleData

data Sample = Sample
    { sVersion :: [ModificationTime]
    , _sData :: !SampleData
    }
Lens.makeLenses ''Sample

sConfigData :: Lens' Sample Config
sConfigData = sData . sConfig . fileData

sThemeData :: Lens' Sample Theme
sThemeData = sData . sTheme . fileData

sLanguageData :: Lens' Sample Language
sLanguageData = sData . sLanguage . fileData

data Sampler = Sampler
    { _sThreadId :: ThreadId
    , getSample :: IO Sample
    , setSelection :: Selection Theme -> Selection Language -> IO ()
    }

filePaths :: Lens.Traversal' (FiledConfig a) FilePath
filePaths f (FiledConfig p ps a) = FiledConfig <$> f p <*> traverse f ps ?? a

sampleFilePaths :: Lens.Traversal' SampleData FilePath
sampleFilePaths f (SampleData conf theme language) =
    SampleData
    <$> filePaths f conf
    <*> filePaths f theme
    <*> filePaths f language

getSampleMTimes :: SampleData -> IO [ModificationTime]
getSampleMTimes sampleData =
    sampleData ^.. sampleFilePaths & traverse getModificationTime

withMTime :: IO SampleData -> IO Sample
withMTime act =
    do
        sampleData <- act
        mtimes <- getSampleMTimes sampleData
        Sample mtimes sampleData & pure

loadConfigFile :: FromJSON a => FilePath -> IO (FiledConfig a)
loadConfigFile path =
    AesonConfig.load path & Writer.runWriterT
    <&> uncurry (flip (FiledConfig path))

loadFromFolder ::
    (HasConfigFolder a, FromJSON a) =>
    FilePath -> Selection a -> IO (FiledConfig a)
loadFromFolder configPath selection =
    loadConfigFile path
    where
        path =
            takeDirectory configPath </> configFolder selection </>
            Text.unpack (getSelection selection) ++ ".json"

load :: Selection Theme -> Selection Language -> FilePath -> IO Sample
load themeName langName configPath =
    do
        config <- loadConfigFile configPath
        SampleData config
            <$> loadFromFolder configPath themeName
            <*> loadFromFolder configPath langName
            & withMTime

maybeReload :: Sample -> FilePath -> IO (Maybe Sample)
maybeReload (Sample oldVer old) newConfigPath =
    do
        mtimes <- getSampleMTimes old
        if mtimes == oldVer
            then pure Nothing
            else load (f sTheme) (f sLanguage) newConfigPath <&> Just
    where
        f l = old ^. l . primaryPath & takeFileName & dropExtension & Text.pack & Selection

new :: (Sample -> IO ()) -> Selection Theme -> Selection Language -> IO Sampler
new sampleUpdated initialTheme initialLang =
    do
        ref <-
            getConfigPath
            >>= load initialTheme initialLang
            >>= E.evaluate
            >>= newMVar
        tid <-
            forkIOUnmasked . forever $
            do
                threadDelay 300000
                let reloadResult old Nothing = (old, Nothing)
                    reloadResult _ (Just newSample) = (newSample, Just newSample)
                mNew <-
                    modifyMVar ref $ \old ->
                    (getConfigPath >>= maybeReload old <&> reloadResult old)
                    `E.catch` \E.SomeException {} -> pure (old, Nothing)
                traverse_ sampleUpdated mNew
        pure Sampler
            { _sThreadId = tid
            , getSample = readMVar ref
            , setSelection =
                \theme lang ->
                takeMVar ref
                >> getConfigPath
                >>= load theme lang
                >>= E.evaluate
                >>= putMVar ref
            }
    where
        getConfigPath = Paths.getDataFileName "config.json"
