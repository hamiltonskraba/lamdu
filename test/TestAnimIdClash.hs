module TestAnimIdClash (test) where

import           Control.Monad.Unit (Unit(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Tree.Diverse (annotations)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.State (HasCursor(..))
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar
import           Test.Lamdu.Gui (verifyLayers)
import qualified Test.Lamdu.GuiEnv as GuiEnv
import           Test.Lamdu.Instances ()
import qualified Test.Lamdu.SugarStubs as Stub

import           Test.Lamdu.Prelude

test :: Test
test =
    testGroup "animid-clash"
    [ testTypeView
    , testFragment
    ]

testTypeView :: Test
testTypeView =
    do
        env <- GuiEnv.make
        TypeView.make typ env ^. Align.tValue . View.vAnimLayers & verifyLayers
    & testCase "typeview"
    where
        typ =
            recType "typ"
            [ (Sugar.TagInfo (Name.AutoGenerated "tag0") "tag0" "tag0", nullType "field0")
            , (Sugar.TagInfo (Name.AutoGenerated "tag1") "tag1" "tag1", nullType "field1")
            , (Sugar.TagInfo (Name.AutoGenerated "tag2") "tag2" "tag2", nullType "field2")
            ]
        nullType entityId = recType entityId []
        recType entityId fields =
            Sugar.CompositeFields
            { Sugar._compositeFields = fields
            , Sugar._compositeExtension = Nothing
            }
            & Sugar.TRecord
            & Sugar.Type entityId

adhocPayload :: ExprGui.Payload
adhocPayload =
    ExprGui.Payload
    { ExprGui._plHiddenEntityIds = []
    , ExprGui._plNeedParens = False
    , ExprGui._plMinOpPrec = 13
    }

testFragment :: Test
testFragment =
    do
        env <-
            GuiEnv.make
            <&> cursor .~ WidgetIds.fromEntityId fragEntityId
        let gui =
                ExpressionEdit.make expr
                & ExprGuiM.run ExpressionEdit.make GuiEnv.dummyAnchors env (const Unit)
                & runIdentity
        let widget = gui ^. Responsive.rWide . Align.tValue
        case widget ^. Widget.wState of
            Widget.StateUnfocused{} -> fail "Expected focused widget"
            Widget.StateFocused mk -> mk (Widget.Surrounding 0 0 0 0) ^. Widget.fLayers & verifyLayers
        pure ()
    & testCase "fragment"
    where
        expr =
            ( Sugar.BodyFragment Sugar.Fragment
                { Sugar._fExpr = Stub.litNum 5
                , Sugar._fHeal = Sugar.TypeMismatch
                , Sugar._fOptions = pure []
                } & Stub.expr
            )
            & Sugar._Node . Sugar.ann . Sugar.plEntityId .~ fragEntityId
            & Stub.addNamesToExpr
            & annotations . Sugar.plData .~ adhocPayload
        fragEntityId = "frag"
