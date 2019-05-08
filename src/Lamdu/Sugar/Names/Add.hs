{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE NoMonomorphismRestriction, TupleSections, DerivingVia #-}

module Lamdu.Sugar.Names.Add
    ( addToWorkArea
    , -- re-export for tests
      InternalName(..), inTag, inContext, runPasses
    ) where

import           Data.Coerce (coerce)
import qualified Control.Lens.Extended as Lens
import           Control.Monad.Reader (ReaderT(..), Reader, runReader, MonadReader(..))
import qualified Control.Monad.Reader as Reader
import           Control.Monad.State (runState, evalState)
import           Control.Monad.Trans.FastWriter (Writer, runWriter, MonadWriter)
import qualified Control.Monad.Trans.FastWriter as Writer
import qualified Data.Char as Char
import           Data.Foldable (fold)
import           Data.MMap (MMap(..))
import qualified Data.MMap as MMap
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Property (Property(..), MkProperty)
import qualified Data.Property as Property
import qualified Data.Set as Set
import           Data.Set.Ordered (OrderedSet)
import qualified Data.Set.Ordered as OrderedSet
import qualified Data.Tuple as Tuple
import           Data.UUID.Types (UUID)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Data.Anchors (anonTag)
import qualified Lamdu.I18N.Texts as Texts
import           Lamdu.Name
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Names.Annotated as Annotated
import           Lamdu.Sugar.Names.CPS (CPS(..), runcps, liftCPS)
import qualified Lamdu.Sugar.Names.Clash as Clash
import           Lamdu.Sugar.Names.NameGen (NameGen)
import qualified Lamdu.Sugar.Names.NameGen as NameGen
import           Lamdu.Sugar.Names.Walk (MonadNaming(..), Disambiguator)
import qualified Lamdu.Sugar.Names.Walk as Walk
import           Lamdu.Sugar.Types

import           Lamdu.Prelude hiding (Map)

type StoredText o = Property o Text

------------------------------
---------- Pass 0 ------------
------------------------------
data P0Name o = P0Name
    { __p0TagName :: StoredText o
    , _p0InternalName :: InternalName
    }
Lens.makeLenses ''P0Name

newtype P0Env i o = P0Env
    { _p0GetNameProp :: T.Tag -> MkProperty i o Text
    }
Lens.makeLenses ''P0Env

newtype Pass0LoadNames i o a =
    Pass0LoadNames { unPass0LoadNames :: ReaderT (P0Env i o) i a }
    deriving newtype (Functor, Applicative, Monad, MonadReader (P0Env i o))

runPass0LoadNames :: P0Env i o -> Pass0LoadNames i o a -> i a
runPass0LoadNames r = (`runReaderT` r) . unPass0LoadNames

instance Monad i => MonadNaming (Pass0LoadNames i o) where
    type OldName (Pass0LoadNames i o) = InternalName
    type NewName (Pass0LoadNames i o) = P0Name o
    type IM (Pass0LoadNames i o) = i
    opRun = Reader.ask <&> runPass0LoadNames
    opWithName _ _ n = CPS $ \inner -> (,) <$> getP0Name n <*> inner
    opGetName _ _ = getP0Name

p0lift :: Monad i => i a -> Pass0LoadNames i o a
p0lift = Pass0LoadNames . lift

getP0Name :: Monad i => InternalName -> Pass0LoadNames i o (P0Name o)
getP0Name internalName =
    do
        nameProp <- Lens.view p0GetNameProp
        nameProp (internalName ^. inTag) ^. Property.mkProperty & p0lift
    <&> (`P0Name` internalName)

------------------------------
---------- Pass 1 ------------
------------------------------

newtype Collider = Collider Clash.Info
instance Semigroup Collider where
    Collider x <> Collider y = Collider (x `Clash.collide` y)

-- 2 wrappers for coerce for readability/safety
uncolliders :: MMap T.Tag Collider -> MMap T.Tag Clash.Info
uncolliders = coerce

colliders :: MMap T.Tag Clash.Info -> MMap T.Tag Collider
colliders = coerce

data P1Out = P1Out
    { _p1Globals :: MMap T.Tag Collider
        -- ^ Used in P2 to check against local hole results
    , _p1Locals :: MMap T.Tag Clash.Info
        -- ^ Used in P2 to check against global hole results
    , _p1Contexts :: MMap T.Tag (Set UUID)
        -- ^ Needed to generate suffixes
    , _p1TypeVars :: OrderedSet UUID
        -- ^ Type vars met
    , _p1Texts :: MMap Text (Set T.Tag)
    }
    deriving stock Generic
    deriving (Semigroup, Monoid) via Generically P1Out
Lens.makeLenses ''P1Out

data P1KindedName o = P1StoredName Annotated.Name (StoredText o) | P1AnonName UUID

data P1Name o = P1Name
    { p1KindedName :: P1KindedName o
    , p1LocalsBelow :: MMap T.Tag Clash.Info
        -- ^ Allow checking collisions for names hidden behind monadic
        -- actions:
    , p1TextsBelow :: MMap Text (Set T.Tag)
        -- ^ We keep the texts below each node so we can check if an
        -- auto-generated name collides with any name in inner scopes
        -- We only use the keys in this map, but we do not strip the
        -- values so all p1TextsBelow can be shared
    }
newtype Pass1PropagateUp (im :: * -> *) (am :: * -> *) a =
    Pass1PropagateUp (Writer P1Out a)
    deriving newtype (Functor, Applicative, Monad, MonadWriter P1Out)
runPass1PropagateUp :: Pass1PropagateUp i o a -> (a, P1Out)
runPass1PropagateUp (Pass1PropagateUp act) = runWriter act

tellSome :: MonadWriter w m => Lens.ASetter' w a -> a -> m ()
tellSome l v = mempty & l .~ v & Writer.tell

instance Monad i => MonadNaming (Pass1PropagateUp i o) where
    type OldName (Pass1PropagateUp i o) = P0Name o
    type NewName (Pass1PropagateUp i o) = P1Name o
    type IM (Pass1PropagateUp i o) = i
    opRun = pure (pure . fst . runPass1PropagateUp)
    opWithName _ = p1Name Nothing
    opGetName mDisambiguator nameType p0Name =
        p1Name mDisambiguator nameType p0Name & runcps

p1Anon :: HasCallStack => Maybe UUID -> CPS (Pass1PropagateUp i o) (P1Name o)
p1Anon Nothing = error "Anon tag with no context"
p1Anon (Just uuid) =
    CPS (Writer.listen <&> Lens.mapped %~ Tuple.swap . (_2 %~ f))
    where
        f innerOut =
            P1Name
            { p1KindedName = P1AnonName uuid
            , p1LocalsBelow = innerOut ^. p1Locals
            , p1TextsBelow = innerOut ^. p1Texts
            }

displayOf :: HasNameTexts env => env -> Text -> Text
displayOf env text
    | Lens.has Lens._Empty text = env ^. nameTexts . emptyName
    | otherwise = text

p1Tagged ::
    Maybe Disambiguator -> Walk.NameType -> P0Name o ->
    CPS (Pass1PropagateUp i o) (P1Name o)
p1Tagged mDisambiguator nameType (P0Name prop internalName) =
    CPS $ \inner ->
    tellSome p1Texts (Lens.singletonAt (prop ^. Property.pVal) (Set.singleton tag))
    *> inner
    & Writer.censor (p1lens <>~ myTags)
    & Writer.listen
    <&> Tuple.swap
    <&> _1 %~ \innerOut ->
    P1Name
    { p1KindedName = P1StoredName aName prop
    , p1LocalsBelow = innerOut ^. p1Locals
    , p1TextsBelow = innerOut ^. p1Texts
    }
    where
        p1lens
            | Walk.isGlobal nameType = p1Globals
            | otherwise = p1Locals . Lens.iso colliders uncolliders  -- makes it have colliders
        myTags = Lens.singletonAt tag (Collider (Clash.infoOf aName))
        tag = internalName ^. inTag
        aName =
            Annotated.Name
            { Annotated._internal = internalName
            , Annotated._disambiguator = mDisambiguator
            , Annotated._nameType = nameType
            }

p1Name ::
    HasCallStack => Maybe Disambiguator -> Walk.NameType -> P0Name o ->
    CPS (Pass1PropagateUp i o) (P1Name o)
p1Name mDisambiguator nameType p0Name =
    -- NOTE: We depend on the anonTag key in the map
    liftCPS (traverse_ tellCtx ctx)
    *> if tag == anonTag
        then p1Anon ctx
        else p1Tagged mDisambiguator nameType p0Name
    where
        tellCtx x =
            tellSome p1Contexts (Lens.singletonAt tag (Set.singleton x)) *>
            when (nameType == Walk.TypeVar) (tellSome p1TypeVars (OrderedSet.singleton x))
        InternalName ctx tag = p0Name ^. p0InternalName

-------------------------------------
---------- Pass1 -> Pass2 -----------
-------------------------------------

tagText :: HasNameTexts env => env -> Text -> Collision -> TagText
tagText env = TagText . displayOf env

makeTagTexts ::
    Texts.Language -> MMap Text (Set T.Tag) -> Map T.Tag TagText
makeTagTexts lang p1texts =
    p1texts
    & Lens.imapped %@~ mkTagTexts
    & fold
    where
        mkTagTexts text tags
            | isCollidingName text tags =
                tags ^.. Lens.folded & Lens.imap (mkCollision text) & Map.fromList
            | otherwise =
                Map.fromSet (const (tagText lang text NoCollision)) tags
        mkCollision text idx tag = (tag, tagText lang text (Collision idx))
        isCollidingName text tagsOfName =
            isReserved lang text || Set.size tagsOfName > 1

isReserved :: Texts.Language -> Text -> Bool
isReserved lang name =
    reservedWords ^. Lens.contains name
    || (name ^? Lens.ix 0 <&> Char.isDigit & fromMaybe False)
    where
        texts = lang ^. Texts.lTexts
        reservedWords =
            texts ^.. Texts.code . traverse <> texts ^.. Texts.name . traverse
            & Set.fromList

toSuffixMap :: MMap T.Tag (Set UUID) -> Map TaggedVarId CollisionSuffix
toSuffixMap tagContexts =
    tagContexts & Lens.imapped %@~ eachTag & (^.. Lens.folded) & mconcat
    where
        eachTag tag contexts = contexts ^.. Lens.folded & Lens.imap (item tag) & Map.fromList
        item tag idx uuid = (TaggedVarId uuid tag, idx)

initialP2Env :: Texts.Language -> P1Out -> P2Env
initialP2Env lang (P1Out globals locals contexts tvs texts) =
    P2Env
    { _p2NameGen = NameGen.initial
    , _p2AnonSuffixes =
        contexts ^@.. Lens.ix anonTag . Lens.folded <&> Tuple.swap & Map.fromList
    , _p2TypeVars =
        NameGen.numberCycle ["a", "b", "c"]
        & filter (not . (`Lens.has` texts) . Lens.ix)
        & zip (tvs ^.. Lens.folded)
        & Map.fromList
    , _p2TagTexts = tagTexts
    , _p2Texts = MMap.keysSet texts
    , _p2TagSuffixes = toSuffixMap collisions
    , _p2TextsAbove = MMap.keysSet globals & Set.map lookupText
    , _p2TagsAbove = uncolliders globals
        -- ^ all globals are "above" everything, and locals add up as
        -- we descend
    , _p2Tags = top
    , _p2NameTexts = lang ^. nameTexts
    }
    where
        lookupText tag =
            tagTexts ^? Lens.ix tag . ttText
            & fromMaybe (error "Cannot find global tag in tagTexts")
        tagTexts = makeTagTexts lang texts
        top = colliders locals <> globals & uncolliders
        -- TODO: Use OrderedSet for nice ordered suffixes
        collisions =
            MMap.filter Clash.isClash top
            & Lens.imapped %@~ \tag _ -> toContexts tag
        toContexts k =
            contexts ^. Lens.at k
            & fromMaybe (error "No Contexts for clashing tag??")


------------------------------
---------- Pass 2 ------------
------------------------------
----- Add tag suffixes -------
------------------------------

-- Like InternalName, but necessarily with a context and non-anonymous tag
data TaggedVarId = TaggedVarId
    { _tvCtx :: UUID -- InternalName's context
    , _tvTag :: T.Tag   -- InternalName's tag
    } deriving (Eq, Ord)

data P2Env = P2Env
    { _p2NameGen :: NameGen UUID -- Map anon name contexts to chosen auto-names
    , _p2AnonSuffixes :: Map UUID CollisionSuffix
        -- ^ Untagged global names (defs/nominals) are presented as
        -- "Unnamed" with a collision suffix. This maps the contexts
        -- (def/nominal ids) to the suffix
    , _p2TypeVars :: Map UUID Text
        -- ^ Names for type variables. Globally unique.
    , _p2TagTexts :: Map T.Tag TagText
    , _p2Texts :: Set Text
        -- ^ The set of all texts seen in P1 traversal (we do not see hole results)
        -- This is used to identify textual collisions in hole result tags
    , _p2TagSuffixes :: Map TaggedVarId CollisionSuffix
        -- ^ When tags collide in the overlapping scopes, the tag gets
        -- a different suffix for each of its entities in ALL scopes
    , _p2TextsAbove :: Set Text
        -- ^ Used to prevent auto-names from re-using texts from above
    , _p2TagsAbove :: MMap T.Tag Clash.Info
        -- ^ All global tags AND local tags from above -- used to
        -- generate "UnknownCollision" inside hole results
    , _p2Tags :: MMap T.Tag Clash.Info
        -- ^ All local AND global tags from all scopes everywhere --
        -- used to check collision of globals in hole results with
        -- everything.
    , _p2NameTexts :: NameTexts Text
    }
Lens.makeLenses ''P2Env

instance HasNameTexts P2Env where nameTexts = p2NameTexts

newtype Pass2MakeNames (im :: * -> *) (am :: * -> *) a = Pass2MakeNames { runPass2MakeNames :: Reader P2Env a }
    deriving newtype (Functor, Applicative, Monad, MonadReader P2Env)

runPass2MakeNamesInitial :: Texts.Language -> P1Out -> Pass2MakeNames i o a -> a
runPass2MakeNamesInitial lang p1out act =
    initialP2Env lang p1out & (runReader . runPass2MakeNames) act

getCollision :: MMap T.Tag Clash.Info -> Annotated.Name -> Pass2MakeNames i o Collision
getCollision tagsBelow aName =
    case mCtx of
    Nothing -> pure NoCollision -- simple tag has no tag collisions
    Just ctx ->
        Lens.view id
        <&> \env ->
        case env ^. p2TagSuffixes . Lens.at (TaggedVarId ctx tag) of
        Just suffix -> Collision suffix
        Nothing ->
            -- In hole results, the collsions suffixes are not precomputed,
            -- but rather computed here:
            if Clash.collide (tags ^. Lens.ix tag) (Clash.infoOf aName) & Clash.isClash
            then
                -- Once a collision, other non-colliding instances
                -- also get a suffix, so we have no idea what suffix
                -- we'll get:
                UnknownCollision
            else NoCollision
            where
                tags
                    -- A global name in a hole result must be checked
                    -- against ALL names everywhere:
                    | Walk.isGlobal (aName ^. Annotated.nameType) = env ^. p2Tags
                    -- A non-global name needs to be checked against
                    -- names above/below (but not sibling scopes)
                    | otherwise =
                        MMap.unionWith Clash.collide tagsBelow (env ^. p2TagsAbove)
    where
        InternalName mCtx tag = aName ^. Annotated.internal

instance Monad i => MonadNaming (Pass2MakeNames i o) where
    type OldName (Pass2MakeNames i o) = P1Name o
    type NewName (Pass2MakeNames i o) = Name o
    type IM (Pass2MakeNames i o) = i
    opRun = Lens.view id <&> flip (runReader . runPass2MakeNames) <&> (pure .)
    opWithName varInfo _ = p2cpsNameConvertor varInfo
    opGetName _ = p2nameConvertor

getTagText :: T.Tag -> StoredText o -> Pass2MakeNames i o TagText
getTagText tag prop =
    Lens.view id
    <&>
    \env ->
    let displayText = displayOf env (prop ^. Property.pVal)
        collision
            | env ^. p2Texts . Lens.contains displayText = UnknownCollision
            | otherwise = NoCollision
    in
    env ^. p2TagTexts . Lens.at tag
    & fromMaybe (TagText displayText collision)

storedName ::
    MMap T.Tag Clash.Info -> Annotated.Name -> StoredText o ->
    Pass2MakeNames i o (Name o)
storedName tagsBelow aName prop =
    StoredName prop
    <$> getTagText tag prop
    <*> getCollision tagsBelow aName
    <&> Stored
    where
        tag = aName ^. Annotated.tag

p2nameConvertor :: Walk.NameType -> P1Name o -> Pass2MakeNames i o (Name o)
p2nameConvertor nameType (P1Name (P1StoredName aName text) tagsBelow _) =
    storedName tagsBelow aName text
    <&>
    case nameType of
    Walk.TaggedNominal -> _Stored . snDisplayText . ttText . Lens.ix 0 %~ Char.toUpper
    _ -> id
p2nameConvertor nameType (P1Name (P1AnonName uuid) _ _) =
    case nameType of
    Walk.Tag -> error "TODO: Refactor types to rule this out"
    Walk.TaggedVar ->
        Lens.view p2NameGen
        <&> evalState (NameGen.existingName uuid)
        <&> AutoGenerated
    Walk.TypeVar ->
        Lens.view (p2TypeVars . Lens.at uuid)
        <&> fromMaybe "?" -- TODO: Type variable in hole result
        <&> AutoGenerated
    Walk.TaggedNominal -> globalAnon
    Walk.GlobalDef -> globalAnon
    where
        globalAnon =
            Lens.view (p2AnonSuffixes . Lens.at uuid)
            <&> fromMaybe bugCollision <&> Unnamed
        -- Holes results should never have unnamed subexprs, instead
        -- of crashing, show -1 as the suffix
        bugCollision = -1

p2cpsNameConvertor :: VarInfo -> Walk.CPSNameConvertor (Pass2MakeNames i o)
p2cpsNameConvertor varInfo (P1Name kName tagsBelow textsBelow) =
    CPS $ \inner ->
    do
        env0 <- Lens.view id
        let accept autoText =
                Lens.nullOf (Lens.ix autoText) textsBelow
                && Set.notMember autoText (env0 ^. p2TextsAbove)
        (newNameForm, env1) <-
            case kName of
            P1StoredName aName text ->
                storedName tagsBelow aName text
                <&> (, env0 & p2TagsAbove . Lens.at tag %~ Just . maybe isClash (Clash.collide isClash))
                where
                    isClash = Clash.infoOf aName
                    tag = aName ^. Annotated.tag
            P1AnonName ctx ->
                NameGen.newName varInfo accept ctx
                <&> AutoGenerated
                & Lens.zoom p2NameGen
                & (`runState` env0)
                & pure
        text <- visible newNameForm <&> (^. _1 . ttText)
        let env2 = env1 & p2TextsAbove %~ Set.insert text
        res <- Reader.local (const env2) inner
        pure (newNameForm, res)

runPasses ::
    Functor i =>
    Texts.Language ->
    (T.Tag -> MkProperty i o Text) ->
    (a -> Pass0LoadNames i o b) ->
    (b -> Pass1PropagateUp i o c) ->
    (c -> Pass2MakeNames i o d) ->
    a -> i d
runPasses lang getNameProp f0 f1 f2 =
    fmap (pass2 . pass1) . pass0
    where
        pass0 = runPass0LoadNames (P0Env getNameProp) . f0
        pass1 = runPass1PropagateUp . f1
        pass2 (x, p1out) = f2 x & runPass2MakeNamesInitial lang p1out

addToWorkArea ::
    Monad i =>
    Texts.Language ->
    (T.Tag -> MkProperty i o Text) ->
    WorkArea InternalName i o (Payload InternalName i o a) ->
    i (WorkArea (Name o) i o (Payload (Name o) i o a))
addToWorkArea lang getNameProp =
    runPasses lang getNameProp f f f
    where
        f = Walk.toWorkArea
