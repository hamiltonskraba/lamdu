-- | Widget to edit the settings
{-# LANGUAGE TemplateHaskell, RankNTypes #-}
module Lamdu.GUI.Settings
     ( StatusWidgets(..), annotationWidget, themeWidget, languageWidget, helpWidget
     , hoist
     , makeStatusWidgets
     ) where

import qualified Control.Lens as Lens
import           Control.Lens.Extended (OneOf)
import           Data.Property (Property, composeLens)
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.View (View)
import           GUI.Momentu.Widgets.EventMapHelp (IsHelpShown(..))
import qualified GUI.Momentu.Widgets.Label as Label
import           GUI.Momentu.Widgets.Spacer (HasStdSpacing)
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.Annotations as Ann
import           Lamdu.Config (HasConfig)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Folder (Selection, _Selection)
import           Lamdu.Config.Theme (Theme, HasTheme)
import qualified Lamdu.GUI.StatusBar.Common as StatusBar
import           Lamdu.GUI.Styled (OneOfT(..))
import qualified Lamdu.GUI.Styled as Styled
import           Lamdu.I18N.Texts (Language, HasLanguage)
import qualified Lamdu.I18N.Texts as Texts
import           Lamdu.Settings (Settings)
import qualified Lamdu.Settings as Settings

import           Lamdu.Prelude

data StatusWidgets f = StatusWidgets
    { _annotationWidget :: StatusBar.StatusWidget f
    , _themeWidget :: StatusBar.StatusWidget f
    , _languageWidget :: StatusBar.StatusWidget f
    , _helpWidget :: StatusBar.StatusWidget f
    }
Lens.makeLenses ''StatusWidgets

hoist ::
    (f GuiState.Update -> g GuiState.Update) ->
    StatusWidgets f -> StatusWidgets g
hoist f (StatusWidgets x y z a) =
    StatusWidgets (h x) (h y) (h z) (h a)
    where
        h = StatusBar.hoist f

unlabeledHeader ::
    Applicative f =>
    OneOf Texts.StatusBar ->
    OneOf Texts.StatusBar -> StatusBar.Header (f View)
unlabeledHeader switchLens categoryLens =
    StatusBar.Header
    { StatusBar.headerSwitchTextLens = switchLens
    , StatusBar.headerCategoryTextLens = categoryLens
    , StatusBar.headerWidget = pure Element.empty
    }

makeAnnotationsSwitcher ::
    ( MonadReader env m, Applicative f
    , HasConfig env, HasTheme env, HasLanguage env
    , TextView.HasStyle env
    , Element.HasAnimIdPrefix env, GuiState.HasCursor env, Hover.HasStyle env
    ) =>
    Property f Ann.Mode -> m (StatusBar.StatusWidget f)
makeAnnotationsSwitcher annotationModeProp =
    do
        mk <- Styled.mkFocusableLabel
        [ (Ann.Evaluation, OneOf Texts.sbEvaluation)
            , (Ann.Types, OneOf Texts.sbTypes)
            , (Ann.None, OneOf Texts.sbNone)
            ] <&> (_2 %~ \(OneOf lens) -> mk (OneOf (Texts.statusBar . lens)))
            & StatusBar.makeSwitchStatusWidget
            (StatusBar.labelHeader Texts.sbSwitchAnnotations Texts.sbAnnotations)
            Config.nextAnnotationModeKeys annotationModeProp

makeStatusWidgets ::
    ( MonadReader env m, Applicative f
    , HasConfig env, HasTheme env, HasStdSpacing env, HasLanguage env
    , Element.HasAnimIdPrefix env, GuiState.HasCursor env, Hover.HasStyle env
    ) =>
    [Selection Theme] -> [Selection Language] ->
    Property f Settings -> m (StatusWidgets f)
makeStatusWidgets themeNames langNames prop =
    StatusWidgets
    <$> makeAnnotationsSwitcher (composeLens Settings.sAnnotationMode prop)
    <*> (themeNames <&> (^. _Selection) & traverse rawOpt
            >>= StatusBar.makeSwitchStatusWidget
            (unlabeledHeader Texts.sbSwitchTheme Texts.sbTheme)
            Config.changeThemeKeys themeProp)
    <*> (langNames <&> (^. _Selection) & traverse rawOpt
            >>= StatusBar.makeSwitchStatusWidget
            (unlabeledHeader Texts.sbSwitchLanguage Texts.sbLanguage)
            Config.changeLanguageKeys langProp)
    <*> ( helpVals >>= StatusBar.makeSwitchStatusWidget
            (StatusBar.labelHeader Texts.sbSwitchHelp Texts.sbHelp)
            Config.helpKeys helpProp
        )
    where
        rawOpt text = Label.makeFocusable text <&> (,) text
        helpVals =
            Styled.mkFocusableLabel
            <&> \mk ->
            [ (HelpNotShown, OneOf Texts.hidden)
            , (HelpShown, OneOf Texts.shown)
            ] <&>
            _2 %~ \(OneOf lens) -> mk (OneOf (Texts.codeUI . lens))
        themeProp = composeLens (Settings.sSelectedTheme . _Selection) prop
        langProp = composeLens (Settings.sSelectedLanguage . _Selection) prop
        helpProp = composeLens Settings.sHelpShown prop
