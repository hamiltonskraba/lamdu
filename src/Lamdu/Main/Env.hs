-- | The Environment threaded in Lamdu main
{-# LANGUAGE TemplateHaskell, MultiParamTypeClasses #-}
module Lamdu.Main.Env
    ( Env(..)
    , evalRes
    , exportActions
    , config
    , theme
    , settings
    , style
    , mainLoop
    , animIdPrefix
    , debugMonitors
    , cachedFunctions
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property)
import qualified Data.Property as Property
import           GUI.Momentu.Animation.Id (AnimId)
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as EventMap
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.Main as MainLoop
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widgets.Choice as Choice
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextEdit as TextEdit
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Cache as Cache
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme(..))
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Data.Db.Layout (ViewM)
import           Lamdu.Data.Tag (HasLanguageIdentifier(..))
import qualified Lamdu.Debug as Debug
import qualified Lamdu.GUI.Main as GUIMain
import qualified Lamdu.GUI.VersionControl.Config as VCConfig
import           Lamdu.I18N.Texts (Language)
import qualified Lamdu.I18N.Texts as Texts
import           Lamdu.Name (HasNameTexts(..))
import           Lamdu.Settings (Settings(..))
import qualified Lamdu.Settings as Settings
import qualified Lamdu.Style as Style

import           Lamdu.Prelude

data Env = Env
    { _evalRes :: GUIMain.EvalResults
    , _exportActions :: GUIMain.ExportActions ViewM
    , _config :: Config
    , _theme :: Theme
    , _settings :: Property IO Settings
    , _style :: Style.Style
    , _mainLoop :: MainLoop.Env
    , _animIdPrefix :: AnimId
    , _debugMonitors :: Debug.Monitors
    , _cachedFunctions :: Cache.Functions
    , _language :: Language
    }
Lens.makeLenses ''Env

instance GUIMain.HasExportActions Env ViewM where exportActions = exportActions
instance GUIMain.HasEvalResults Env ViewM where evalResults = evalRes
instance Settings.HasSettings Env where settings = settings . Property.pVal
instance Style.HasStyle Env where style = style
instance MainLoop.HasMainLoopEnv Env where mainLoopEnv = mainLoop
instance Spacer.HasStdSpacing Env where stdSpacing = Theme.theme . Theme.stdSpacing
instance GuiState.HasCursor Env
instance GuiState.HasState Env where state = mainLoop . GuiState.state
instance TextEdit.HasStyle Env where style = style . Style.base
instance TextView.HasStyle Env where style = TextEdit.style . TextView.style
instance Theme.HasTheme Env where theme = theme
instance Config.HasConfig Env where config = config
instance Hover.HasStyle Env where style = theme . Hover.style
instance VCConfig.HasTheme Env where theme = theme . Theme.versionControl
instance VCConfig.HasConfig Env where config = config . Config.versionControl
instance Menu.HasConfig Env where
    config = Menu.configLens (config . Config.menu) (theme . Theme.menu)
instance SearchMenu.HasTermStyle Env where termStyle = theme . Theme.searchTerm
instance Debug.HasMonitors Env where monitors = debugMonitors
instance Cache.HasFunctions Env where functions = cachedFunctions
instance Element.HasAnimIdPrefix Env where animIdPrefix = animIdPrefix
instance Dir.HasLayoutDir Env where layoutDir = language . Dir.layoutDir
instance Dir.HasTexts Env where texts = language . Dir.texts
instance Glue.HasTexts Env where texts = language . Glue.texts
instance EventMap.HasTexts Env where texts = language . EventMap.texts
instance Choice.HasTexts Env where texts = language . Choice.texts
instance TextEdit.HasTexts Env where texts = language . TextEdit.texts
instance Grid.HasTexts Env where texts = language . Grid.texts
instance Menu.HasTexts Env where texts = language . Menu.texts
instance SearchMenu.HasTexts Env where texts = language . SearchMenu.texts
instance HasNameTexts Env where nameTexts = language . nameTexts
instance Texts.HasLanguage Env where language = language
instance HasLanguageIdentifier Env where languageIdentifier = language . languageIdentifier
