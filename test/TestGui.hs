{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module TestGui where

import qualified Control.Lens as Lens
import           Control.Monad.Unit (Unit(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Vector.Vector2 (Vector2(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Rect (Rect(..))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.State (Gui, HasState, HasCursor(..), VirtualCursor(..))
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import           GUI.Momentu.Widgets.Spacer (HasStdSpacing)
import qualified Graphics.UI.GLFW as GLFW
import           Graphics.UI.GLFW.Events (Event(..), KeyEvent(..))
import qualified Lamdu.Cache as Cache
import           Lamdu.Config (HasConfig)
import           Lamdu.Config.Theme (HasTheme)
import           Lamdu.Data.Db.Layout (ViewM)
import qualified Lamdu.Data.Db.Layout as DbLayout
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import           Lamdu.GUI.ExpressionEdit.BinderEdit (makeBinderBodyEdit)
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name)
import           Lamdu.Settings (HasSettings)
import           Lamdu.Style (HasStyle)
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar
import           Revision.Deltum.Transaction (Transaction)
import           System.Directory (listDirectory)
import qualified Test.Lamdu.GuiEnv as GuiEnv
import           Test.Lamdu.Instances ()
import           Test.Lamdu.Sugar (convertWorkArea, testProgram)
import           Unsafe.Coerce (unsafeCoerce)

import           Test.Lamdu.Prelude

type T = Transaction

test :: Test
test =
    testGroup "gui-tests"
    [ testOpPrec
    , testFragmentSize
    , testLambdaDelete
    , testConsistentNavigation
    ]

replExpr ::
    Lens.Traversal' (Sugar.WorkArea name i o a) (Sugar.Expression name i o a)
replExpr = Sugar.waRepl . Sugar.replExpr . Sugar.bContent . Sugar._BinderExpr

wideFocused :: Lens.Traversal' (Responsive a) (Widget.Surrounding -> Widget.Focused a)
wideFocused = Responsive.rWide . Align.tValue . Widget.wState . Widget._StateFocused

makeReplGui ::
    ( HasState env, HasStdSpacing env, HasConfig env, HasTheme env
    , HasSettings env, HasStyle env
    ) =>
    Cache.Functions -> env -> T ViewM (Gui Responsive (T ViewM))
makeReplGui cache env =
    do
        workArea <- convertWorkArea cache
        let repl = workArea ^. Sugar.waRepl . Sugar.replExpr
        let replExprId =
                repl ^. Sugar.bContent . SugarLens.binderContentResultExpr
                . Sugar._PNode . Sugar.ann
                & WidgetIds.fromExprPayload
        gui <-
            makeBinderBodyEdit repl
            & GuiState.assignCursor WidgetIds.replId replExprId
            & ExprGuiM.run ExpressionEdit.make DbLayout.guiAnchors env id
        unless (Lens.has wideFocused gui) (fail "Red cursor!")
        pure gui

focusedWidget :: Responsive a -> Widget.Focused a
focusedWidget gui = (gui ^?! wideFocused) (Widget.Surrounding 0 0 0 0)

mApplyEvent ::
    ( HasState env, HasStdSpacing env, HasConfig env, HasTheme env
    , HasSettings env, HasStyle env
    ) =>
    Cache.Functions -> env -> VirtualCursor -> Event ->
    T ViewM (Maybe GuiState.Update)
mApplyEvent cache env virtCursor event =
    do
        gui <- makeReplGui cache env
        let eventMap =
                (focusedWidget gui ^. Widget.fEventMap)
                Widget.EventContext
                { Widget._eVirtualCursor = virtCursor
                , Widget._ePrevTextRemainder = ""
                }
        runIdentity (E.lookup (Identity Nothing) event eventMap) & sequenceA

applyEvent ::
    ( HasState env, HasStdSpacing env, HasConfig env, HasTheme env
    , HasSettings env, HasStyle env
    ) =>
    Cache.Functions -> env -> VirtualCursor -> Event -> T ViewM env
applyEvent cache env virtCursor event =
    mApplyEvent cache env virtCursor event <&> (^?! Lens._Just)
    <&> (`GuiState.update` env)

fromWorkArea ::
    Cache.Functions ->
    Lens.ATraversal'
    (Sugar.WorkArea (Name (T ViewM)) (T ViewM) (T ViewM)
        (Sugar.Payload (Name (T ViewM)) (T ViewM) (T ViewM) ExprGui.Payload)) a ->
    T ViewM a
fromWorkArea cache path =
    convertWorkArea cache <&> (^?! Lens.cloneTraversal path)

simpleKeyEvent :: GLFW.Key -> Event
simpleKeyEvent key =
    EventKey KeyEvent
    { keKey = key
    , keScanCode = 0 -- dummy
    , keModKeys = mempty
    , keState = GLFW.KeyState'Pressed
    , keChar = Nothing
    }

dummyVirt :: VirtualCursor
dummyVirt = VirtualCursor (Rect 0 0)

-- | Test for issue #411
-- https://trello.com/c/IF6kY9AZ/411-deleting-lambda-parameter-red-cursor
testLambdaDelete :: Test
testLambdaDelete =
    testCase "delete-lambda" $
    GuiEnv.make >>=
    \baseEnv ->
    testProgram "simple-lambda.json" $
    \cache ->
    do
        paramCursor <-
            fromWorkArea cache
            (replExpr . Sugar._PNode . Sugar.val. Sugar._BodyLam . Sugar.lamFunc .
             Sugar.fParams . Sugar._Params . Lens.ix 0 . Sugar.fpInfo .
             Sugar.piTag . Sugar.tagInfo . Sugar.tagInstance)
            <&> WidgetIds.fromEntityId
        let delEvent = simpleKeyEvent GLFW.Key'Backspace
        env0 <- applyEvent cache (baseEnv & cursor .~ paramCursor) dummyVirt delEvent
        -- One delete replaces the param tag, next delete deletes param
        env1 <- applyEvent cache env0 dummyVirt delEvent
        _ <- makeReplGui cache env1
        pure ()

-- | Test for issue #410
-- https://trello.com/c/00mxkLRG/410-navigating-to-fragment-affects-layout
testFragmentSize :: Test
testFragmentSize =
    testCase "fragment-size" $
    GuiEnv.make >>=
    \baseEnv ->
    testProgram "simple-fragment.json" $
    \cache ->
    do
        frag <- fromWorkArea cache (replExpr . Sugar._PNode . Sugar.ann)
        guiCursorOnFrag <-
            baseEnv
            & cursor .~ WidgetIds.fromExprPayload frag
            & makeReplGui cache
        guiCursorElseWhere <- makeReplGui cache baseEnv
        unless (guiCursorOnFrag ^. sz == guiCursorElseWhere ^. sz) (fail "fragment size inconsistent")
    where
        sz = Responsive.rWide . Align.tValue . Element.size

-- | Test for issue #375
-- https://trello.com/c/KFLJPNmO/375-operator-precedence-crosses-lambda-boundaries-add-test
testOpPrec :: Test
testOpPrec =
    testCase "apply-operator" $
    GuiEnv.make >>=
    \baseEnv ->
    testProgram "simple-lambda.json" $
    \cache ->
    do
        holeId <-
            fromWorkArea cache
            (replExpr . Sugar._PNode . Sugar.val . Sugar._BodyLam . Sugar.lamFunc .
             Sugar.fBody . Sugar.bContent . Sugar._BinderExpr .
             Sugar._PNode . Sugar.ann . Sugar.plEntityId)
            <&> HoleWidgetIds.make
            <&> HoleWidgetIds.hidClosed
        workArea <- convertWorkArea cache
        _ <- EventKey KeyEvent
            { keKey = GLFW.Key'7
            , keScanCode = 0 -- dummy
            , keModKeys = GLFW.ModifierKeys True False False False
            , keState = GLFW.KeyState'Pressed
            , keChar = Just '&'
            } & applyEvent cache (baseEnv & cursor .~ holeId) dummyVirt
        workArea' <- convertWorkArea cache
        unless (workAreaEq workArea workArea') (fail "bad operator precedence")

workAreaEq ::
    forall a m.
    Eq a =>
    Sugar.WorkArea (Name (T m)) (T m) (T m)
    (Sugar.Payload (Name (T m)) (T m) (T m) a) ->
    Sugar.WorkArea (Name (T m)) (T m) (T m)
    (Sugar.Payload (Name (T m)) (T m) (T m) a) ->
    Bool
workAreaEq x y =
    x' == unsafeCoerce y
    where
        x' =
            unsafeCoerce x ::
                Sugar.WorkArea (Name Unit) Unit Unit
                (Sugar.Payload (Name Unit) Unit Unit a)

testConsistentNavigationForProg :: FilePath -> IO ()
testConsistentNavigationForProg filename =
    GuiEnv.make >>=
    \baseEnv ->
    testProgram filename $
    \cache ->
    do
        let testDir posEnv posVirt (way, back) =
                mApplyEvent cache posEnv posVirt (simpleKeyEvent way)
                >>=
                \case
                Nothing -> pure ()
                Just updThere ->
                    mApplyEvent cache
                    (GuiState.update updThere posEnv)
                    (updThere ^?! GuiState.uVirtualCursor . traverse)
                    (simpleKeyEvent back)
                    >>=
                    \case
                    Nothing -> fail (baseInfo <> "can't move back with cursor keys")
                    Just updBack | updBack ^? GuiState.uCursor . traverse /= Just (posEnv ^. cursor) ->
                        baseInfo <> "moving back with cursor keys goes to different place: " <>
                        show (updBack ^. GuiState.uCursor)
                        & fail
                    Just{} -> pure ()
                where
                    baseInfo =
                        filename <> "/" <> show (posEnv ^. GuiState.cursor, way, back) <> ": "
        baseGui <- makeReplGui cache baseEnv
        let focused = focusedWidget baseGui
        let testProgPos pos =
                do
                    upd <- enter ^. Widget.enterResultEvent
                    let newEnv = GuiState.update upd baseEnv
                    traverse_ (testDir newEnv virtCursor) dirs
                where
                    enter = (focused ^?! Widget.fMEnterPoint . Lens._Just) pos
                    virtCursor = VirtualCursor (enter ^. Widget.enterResultRect)
        let size = baseGui ^. Responsive.rWide . Align.tValue . Widget.wSize
        Vector2 <$> [0, 0.1 .. 1] <*> [0, 0.3 .. 1] <&> (* size)
            & traverse_ testProgPos
    where
        dirs =
            [ (GLFW.Key'Up, GLFW.Key'Down)
            , (GLFW.Key'Down, GLFW.Key'Up)
            , (GLFW.Key'Left, GLFW.Key'Right)
            , (GLFW.Key'Right, GLFW.Key'Left)
            ]

testConsistentNavigation :: Test
testConsistentNavigation =
    listDirectory "test/programs"
    <&> filter (`notElem` skipped)
    >>= traverse testConsistentNavigationForProg & void
    & testCase "consistent-navigation"
    where
        skipped =
            [ -- These tests import a program without first importing freshdb.
              -- This program, saved with an old codec (the first version),
              -- is not compatible with that
              "old-codec-factorial.json"
            ]
