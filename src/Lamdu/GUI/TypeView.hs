{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, TemplateHaskell, TupleSections #-}
module Lamdu.GUI.TypeView
    ( make, makeScheme
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text as Text
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (Aligned(..), WithTextPos(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Animation.Id as AnimId
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Draw as MDraw
import           GUI.Momentu.Element (Element)
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.Glue ((/-/), (/|/))
import qualified GUI.Momentu.Glue as Glue
import           GUI.Momentu.View (View(..))
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.GridView as GridView
import qualified GUI.Momentu.Widgets.Label as Label
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import           Lamdu.Config.Theme (HasTheme)
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.GUI.ExpressionEdit.TagEdit (makeTagView)
import qualified Lamdu.GUI.NameView as NameView
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Texts as Texts
import           Lamdu.Name (Name, HasNameTexts)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

newtype Prec = Prec Int deriving (Eq, Ord, Show)

data CompositeRow a = CompositeRow
    { _crPre :: a
    , _crTag :: a
    , _crSpace :: a
    , _crVal :: a
    , _crPost :: a
    } deriving (Functor, Foldable, Traversable)

Lens.makeLenses ''CompositeRow

horizSetCompositeRow :: CompositeRow (WithTextPos View) -> CompositeRow (Aligned View)
horizSetCompositeRow r =
    CompositeRow
    { _crPre = r ^. crPre & Align.fromWithTextPos 0
    , _crTag = r ^. crTag & Align.fromWithTextPos 1
    , _crSpace = r ^. crSpace & Align.fromWithTextPos 0.5
    , _crVal = r ^. crVal & Align.fromWithTextPos 0
    , _crPost = r ^. crPost & Align.fromWithTextPos 0
    }

sanitize :: Text -> Text
sanitize = Text.replace "\0" ""

grammar ::
    ( MonadReader env m, TextView.HasStyle env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) =>
    Text -> m (WithTextPos View)
grammar = Styled.grammar . Label.make . sanitize

parensAround ::
    ( MonadReader env m, TextView.HasStyle env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) =>
    WithTextPos View -> m (WithTextPos View)
parensAround view =
    do
        openParenView <- grammar "("
        closeParenView <- grammar ")"
        Glue.hbox Dir.LeftToRight [openParenView, view, closeParenView] & pure

parens ::
    ( MonadReader env m, TextView.HasStyle env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) =>
    Prec -> Prec -> WithTextPos View -> m (WithTextPos View)
parens parent my view
    | parent > my = parensAround view
    | otherwise = pure view

makeTFun ::
    ( MonadReader env m, HasTheme env, Spacer.HasStdSpacing env
    , Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    Prec -> Sugar.Type (Name f) -> Sugar.Type (Name f) -> m (WithTextPos View)
makeTFun parentPrecedence a b =
    Glue.hbox <*>
    ( case a ^. Sugar.tBody of
        Sugar.TRecord (Sugar.CompositeFields [] Nothing) ->
            [ grammar "|"
            , Spacer.stdHSpace <&> WithTextPos 0
            ]
        _ ->
            [ makeInternal (Prec 1) a
            , Styled.grammar (Styled.label (Texts.code . Texts.arrow))
            ]
        ++ [makeInternal (Prec 0) b]
        & sequence
    ) >>= parens parentPrecedence (Prec 0)

makeTInst ::
    ( MonadReader env m, Spacer.HasStdSpacing env, HasTheme env
    , Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    Prec -> Sugar.TId (Name f) -> [(Name f, Sugar.Type (Name f))] ->
    m (WithTextPos View)
makeTInst parentPrecedence tid typeParams =
    do
        hspace <- Spacer.stdHSpace
        let afterName paramsView = tconsName /|/ pure hspace /|/ paramsView
        let makeTypeParam i (tParamId, arg) =
                do
                    paramIdView <-
                        NameView.make tParamId & disambAnimId ["param", show i]
                    typeView <- makeInternal (Prec 0) arg
                    pure
                        [ Align.fromWithTextPos 1 paramIdView
                        , Aligned 0.5 hspace
                        , Align.fromWithTextPos 0 typeView
                        ]
        case typeParams of
            [] -> tconsName
            [(_, arg)] ->
                makeInternal (Prec 0) arg
                & afterName
                >>= parens parentPrecedence (Prec 0)
            params ->
                gridViewTopLeftAlign <*> Lens.itraverse makeTypeParam params
                <&> Align.toWithTextPos
                >>= (Styled.addValPadding ??)
                >>= addTypeBG
                & afterName
    where
        tconsName =
            NameView.make (tid ^. Sugar.tidName) & disambAnimId ["TCons"]
        disambAnimId suffixes =
            Reader.local (Element.animIdPrefix <>~ (suffixes <&> BS8.pack))

addTypeBG ::
    (Element a, MonadReader env m, HasTheme env, Element.HasAnimIdPrefix env) =>
    a -> m a
addTypeBG view =
    do
        color <- Lens.view (Theme.theme . Theme.typeFrameBGColor)
        bgId <- Element.subAnimId ?? ["bg"]
        view
            & MDraw.backgroundColor bgId color
            & pure

makeEmptyComposite ::
    ( MonadReader env m, TextView.HasStyle env, HasTheme env
    , Element.HasAnimIdPrefix env
    ) =>
    m (WithTextPos View)
makeEmptyComposite = grammar "Ø"

makeField ::
    ( MonadReader env m, HasTheme env, Texts.HasLanguage env
    , Spacer.HasStdSpacing env, Element.HasAnimIdPrefix env
    ) =>
    (Sugar.TagInfo (Name f), Sugar.Type (Name f)) ->
    m (WithTextPos View, WithTextPos View)
makeField (tag, fieldType) =
    (,)
    <$> makeTagView tag
    <*> makeInternal (Prec 0) fieldType

makeVariantField ::
    ( MonadReader env m, Spacer.HasStdSpacing env
    , HasTheme env, Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    (Sugar.TagInfo (Name f), Sugar.Type (Name f)) ->
    m (WithTextPos View, WithTextPos View)
makeVariantField (tag, Sugar.Type _ (Sugar.TRecord (Sugar.CompositeFields [] Nothing))) =
    makeTagView tag <&> (, Element.empty)
    -- ^ Nullary data constructor
makeVariantField (tag, fieldType) = makeField (tag, fieldType)

gridViewTopLeftAlign ::
    ( MonadReader env m, Dir.HasLayoutDir env
    , Traversable vert, Traversable horiz
    ) =>
    m (vert (horiz (Aligned View)) -> Aligned View)
gridViewTopLeftAlign =
    GridView.make <&>
    \mkGrid views ->
    let (alignPoints, view) = mkGrid views
    in  case alignPoints ^? traverse . traverse of
        Nothing -> Aligned 0 view
        Just x -> x & Align.value .~ view

makeComposite ::
    ( MonadReader env m, HasTheme env, Spacer.HasStdSpacing env
    , Element.HasAnimIdPrefix env, Dir.HasLayoutDir env, HasNameTexts env
    ) =>
    Text -> Text ->
    m (WithTextPos View) -> m (WithTextPos View) ->
    ((Sugar.TagInfo (Name f), Sugar.Type (Name f)) ->
         m (WithTextPos View, WithTextPos View)) ->
    Sugar.CompositeFields (Name f) (Sugar.Type (Name f)) ->
    m (WithTextPos View)
makeComposite o c mkPre mkPost mkField composite =
    case composite of
    Sugar.CompositeFields [] Nothing -> makeEmptyComposite
    Sugar.CompositeFields fields extension ->
        do
            opener <- grammar o
            closer <- grammar c
            fieldsView <-
                gridViewTopLeftAlign <*>
                ( traverse mkField fields
                <&> map toRow
                <&> Lens.ix 0 . crPre .~ pure opener
                <&> Lens.reversed . Lens.ix 0 . crPost .~ pure closer
                <&> Lens.imap addAnimIdPrefix
                >>= traverse sequenceA
                <&> map horizSetCompositeRow )
                <&> Align.alignmentRatio . _1 .~ 0.5
            let barWidth
                    | null fields = 150
                    | otherwise = fieldsView ^. Element.width
            extView <-
                case extension of
                Nothing -> pure Element.empty
                Just var ->
                    do
                        sqrId <- Element.subAnimId ?? ["square"]
                        let sqr =
                                View.unitSquare sqrId
                                & Element.scale (Vector2 barWidth 10)
                        lastLine <- mkPre /|/ NameView.make var <&> (^. Align.tValue)
                        pure (Aligned 0.5 sqr) /-/ pure (Aligned 0.5 lastLine)
            Styled.addValPadding
                <*> (pure fieldsView /-/ pure extView <&> Align.toWithTextPos)
    where
        addAnimIdPrefix i row =
            row <&> Reader.local (Element.animIdPrefix %~ AnimId.augmentId i)
        toRow (t, v) =
            CompositeRow mkPre (pure t) space (pure v) mkPost
            where
                space
                    | v ^. Align.tValue . Element.width == 0 = pure Element.empty
                    | otherwise = Spacer.stdHSpace <&> WithTextPos 0

makeInternal ::
    ( MonadReader env m, Spacer.HasStdSpacing env, HasTheme env
    , Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    Prec -> Sugar.Type (Name f) -> m (WithTextPos View)
makeInternal parentPrecedence (Sugar.Type entityId tbody) =
    case tbody of
    Sugar.TVar var -> NameView.make var
    Sugar.TFun a b -> makeTFun parentPrecedence a b
    Sugar.TInst typeId typeParams -> makeTInst parentPrecedence typeId typeParams
    Sugar.TRecord composite -> makeComposite "{" "}" (pure Element.empty) (grammar ",") makeField composite
    Sugar.TVariant composite ->
        makeComposite "+{" "}" (grammar "or: ") (pure Element.empty) makeVariantField composite
    & Reader.local (Element.animIdPrefix .~ animId)
    where
        animId = WidgetIds.fromEntityId entityId & Widget.toAnimId

make ::
    ( MonadReader env m, HasTheme env, Spacer.HasStdSpacing env
    , Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    Sugar.Type (Name f) -> m (WithTextPos View)
make t = makeInternal (Prec 0) t & Styled.withColor TextColors.typeTextColor

makeScheme ::
    ( MonadReader env m, HasTheme env, Spacer.HasStdSpacing env
    , Element.HasAnimIdPrefix env, Texts.HasLanguage env
    ) =>
    Sugar.Scheme (Name f) -> m (WithTextPos View)
makeScheme s = make (s ^. Sugar.schemeType)
