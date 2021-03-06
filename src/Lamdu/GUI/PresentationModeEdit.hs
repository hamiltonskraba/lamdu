-- | Choice widget for presentation mode
{-# LANGUAGE RankNTypes #-}
module Lamdu.GUI.PresentationModeEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import           Data.Property (Property)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.Hover as Hover
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Choice as Choice
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config.Theme (HasTheme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.GUI.Styled (OneOfT(..))
import qualified Lamdu.GUI.Styled as Styled
import           Lamdu.I18N.Texts (Texts)
import qualified Lamdu.I18N.Texts as Texts
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

lens :: Sugar.SpecialArgs dummy -> Lens.Lens' (Texts a) a
lens mode =
    Texts.codeUI .
    case mode of
    Sugar.Verbose -> Texts.pModeVerbose
    Sugar.Object{} -> Texts.pModeOO
    Sugar.Infix{} -> Texts.pModeInfix

{-# ANN make ("HLint: ignore Use head"::String) #-}
make ::
    ( Applicative f, MonadReader env m, HasTheme env
    , Element.HasAnimIdPrefix env, TextView.HasStyle env, GuiState.HasCursor env
    , Hover.HasStyle env, Texts.HasLanguage env
    ) =>
    Widget.Id ->
    Sugar.BinderParams name i o ->
    Property f Sugar.PresentationMode ->
    m (Align.TextWidget f)
make myId (Sugar.Params params) prop =
    do
        theme <- Lens.view Theme.theme
        pairs <-
            traverse mkPair [Sugar.Object (paramTags !! 0), Sugar.Verbose, Sugar.Infix (paramTags !! 0) (paramTags !! 1)]
            & Reader.local
                (TextView.style . TextView.styleColor .~ theme ^. Theme.textColors . TextColors.presentationChoiceColor)
        defConfig <-
            Choice.defaultConfig
            <*> Lens.view (Texts.texts . Texts.codeUI . Texts.presentationMode)
        Choice.make ?? prop ?? pairs
            ?? defConfig ?? myId
            <&> Element.scale (theme ^. Theme.presentationChoiceScaleFactor)
    where
        paramTags = params ^.. traverse . Sugar.fpInfo . Sugar.piTag . Sugar.tagInfo . Sugar.tagVal
        mkPair mode = Styled.mkFocusableLabel ?? OneOf (lens mode) <&> (,) mode
make _ _ _ =
    -- This shouldn't happen?
    pure Element.empty
