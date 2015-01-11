{-# LANGUAGE RecordWildCards, OverloadedStrings #-}

module Lamdu.GUI.ExpressionEdit.HoleEdit.Closed
  ( make
  ) where

import           Control.Applicative (Applicative(..), (<$>))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Control.Monad (guard)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Either.Utils (runMatcherT, justToLeft)
import           Control.MonadA (MonadA)
import           Data.Maybe.Utils (maybeToMPlus)
import           Data.Monoid (Monoid(..), (<>))
import qualified Data.Store.Transaction as Transaction
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.GUI.BottleWidgets as BWidgets
import           Lamdu.GUI.ExpressionEdit.HoleEdit.Common (addBackground)
import           Lamdu.GUI.ExpressionEdit.HoleEdit.Info (HoleIds(..))
import           Lamdu.GUI.ExpressionGui (ExpressionGui(..))
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.WidgetEnvT as WE
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Sugar.AddNames.Types (Name(..), ExpressionN)
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.Types as Sugar

type T = Transaction.Transaction

make ::
  MonadA m =>
  Sugar.Hole (Name m) m (ExprGuiM.SugarExpr m) ->
  Sugar.Payload m ExprGuiM.Payload ->
  HoleIds ->
  ExprGuiM m (Widget.Id, ExpressionGui m)
make hole pl hids@HoleIds{..} =
  do
    Config.Hole{..} <- ExprGuiM.widgetEnv WE.readConfig <&> Config.hole
    let
      addEventMap =
        _2 . ExpressionGui.egWidget %~
        Widget.weakerEvents (openHoleEventMap holeOpenKeys hids)
    fmap addEventMap $ runMatcherT $ do
      justToLeft $ do
        arg <- maybeToMPlus $ hole ^. Sugar.holeMArg
        gui <- lift $ makeWrapper arg hids
        return (hid, gui)
      justToLeft $ do
        guard $ not isHoleResult -- Avoid suggesting inside hole results
        guard . Lens.nullOf ExprLens.valHole $ suggested ^. Sugar.hsValue
        (destId, gui) <- lift $ makeSuggested suggested hids
        return (destId, gui)
      gui <- makeSimple hids & lift
      return (hidOpen, gui)
  & ExpressionGui.stdWrapIn _2 pl
  where
    isHoleResult =
      Lens.nullOf (Sugar.plData . ExprGuiM.plStoredEntityIds . Lens.traversed) pl
    suggested = hole ^. Sugar.holeSuggested

openHoleEventMap ::
  Applicative f => [ModKey] -> HoleIds -> Widget.EventHandlers f
openHoleEventMap keys HoleIds{..} =
  Widget.keysEventMapMovesCursor keys doc $ pure hidOpen
  where
    doc = E.Doc ["Navigation", "Hole", "Open"]

makeUnwrapEventMap ::
  (MonadA m, MonadA f) =>
  Sugar.HoleArg f (ExpressionN f a) -> HoleIds ->
  ExprGuiM m (Widget.EventHandlers (T f))
makeUnwrapEventMap arg hids = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  let Config.Hole{..} = Config.hole config
  pure $
    case arg ^? Sugar.haUnwrap . Sugar._UnwrapMAction . Lens._Just of
    Just unwrap ->
      Widget.keysEventMapMovesCursor
      (holeUnwrapKeys ++ Config.delKeys config)
      (E.Doc ["Edit", "Unwrap"]) $ WidgetIds.fromEntityId <$> unwrap
    Nothing -> openHoleEventMap (Config.wrapKeys config) hids

modifyWrappedEventMap ::
  (MonadA m, Applicative f) =>
  Config -> Bool -> Sugar.HoleArg m (ExpressionN m a) -> HoleIds ->
  Widget.EventHandlers f ->
  Widget.EventHandlers f
modifyWrappedEventMap config argIsFocused arg HoleIds{..} eventMap
  | argIsFocused =
    eventMap <>
    Widget.keysEventMapMovesCursor (Config.leaveSubexpressionKeys config)
    (E.Doc ["Navigation", "Go to parent wrapper"]) (pure hid)
  | otherwise =
    Widget.keysEventMapMovesCursor (Config.enterSubexpressionKeys config)
    (E.Doc ["Navigation", "Go to wrapped expr"]) .
    pure . FocusDelegator.notDelegatingId . WidgetIds.fromEntityId $
    arg ^. Sugar.haExpr . Sugar.rPayload . Sugar.plEntityId

makeWrapper ::
  MonadA m =>
  Sugar.HoleArg m (ExpressionN m ExprGuiM.Payload) ->
  HoleIds -> ExprGuiM m (ExpressionGui m)
makeWrapper arg hids@HoleIds{..} = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  let
    Config.Hole{..} = Config.hole config
    bgColor =
      config &
      case arg ^. Sugar.haUnwrap of
      Sugar.UnwrapMAction {} -> Config.typeIndicatorMatchColor
      Sugar.UnwrapTypeMismatch {} -> Config.typeIndicatorErrorColor
    frameWidth = realToFrac <$> Config.typeIndicatorFrameWidth config
    padding = realToFrac <$> Config.valFramePadding config
  argGui <-
    arg ^. Sugar.haExpr
    & ExprGuiM.makeSubexpression 0
  let argIsFocused = argGui ^. ExpressionGui.egWidget . Widget.wIsFocused
  gui <-
    argGui
    & ExpressionGui.egWidget . Widget.wEventMap %~
      modifyWrappedEventMap config argIsFocused arg hids
    & ExpressionGui.pad (padding + frameWidth)
    & ExpressionGui.egWidget %~
      Widget.addInnerFrame
      (Config.layerHoleBG (Config.layers config))
      frameId bgColor frameWidth
    & ExpressionGui.egWidget %%~ makeFocusable hids
  unwrapEventMap <- makeUnwrapEventMap arg hids
  return (gui & ExpressionGui.egWidget %~ Widget.weakerEvents unwrapEventMap)
  where
    frameId = Widget.toAnimId hidClosed <> ["hole frame"]

makeSuggested ::
  MonadA m =>
  Sugar.HoleSuggested (Name m) m ->
  HoleIds -> ExprGuiM m (Widget.Id, ExpressionGui m)
makeSuggested suggested hids@HoleIds{..} = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  let Config.Hole{..} = Config.hole config
  gui <-
    (suggested ^. Sugar.hsMakeConverted)
    & ExprGuiM.transaction
    <&> Lens.mapped . Lens.mapped .~ ExprGuiM.emptyPayload NearestHoles.none
    <&> Lens.mapped . Lens.mapped . ExprGuiM.plShowType .~ ExprGuiM.DoNotShowType
    >>= ExprGuiM.makeSubexpression 0
    >>= ExpressionGui.egWidget %%~
        makeFocusable hids .
        Widget.tint (Config.suggestedValueTint config) .
        Widget.scale (realToFrac <$> Config.suggestedValueScaleFactor config) .
        (Widget.wEventMap .~ mempty)
  return $
    if fullySuggested
    then (hidClosed, gui)
    else
      ( hidOpen
      , gui
        & ExpressionGui.egWidget %~
          addBackground hidClosed (Config.layers config) holeClosedBGColor
      )
  where
    fullySuggested =
      Lens.nullOf (ExprLens.subExprs . ExprLens.valHole) $
      suggested ^. Sugar.hsValue

makeSimple :: MonadA m => HoleIds -> ExprGuiM m (ExpressionGui m)
makeSimple hids@HoleIds{..} = do
  config <- ExprGuiM.widgetEnv WE.readConfig
  let Config.Hole{..} = Config.hole config
  ExprGuiM.widgetEnv
    (BWidgets.makeTextViewWidget "  " (Widget.toAnimId hidClosed))
    <&> addBackground hidClosed (Config.layers config) holeClosedBGColor
    <&> ExpressionGui.fromValueWidget
    >>= ExpressionGui.egWidget %%~ makeFocusable hids

makeFocusable :: (MonadA m, Applicative f) => HoleIds -> Widget f -> ExprGuiM m (Widget f)
makeFocusable HoleIds{..} = ExprGuiM.widgetEnv . BWidgets.makeFocusableView hid
