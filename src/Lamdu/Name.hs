{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Name
    ( Stored, CollisionSuffix
    , Collision(..), _NoCollision, _Collision
    , visible
    , TagText(..), ttText, ttCollision
    , StoredName(..), snProp, snDisplayText, snTagCollision
    , Name(..), _AutoGenerated, _Stored
    ) where

import qualified Control.Lens as Lens
import           Data.Property (Property)
import           Lamdu.Precedence (HasPrecedence(..))

import           Lamdu.Prelude

type Stored = Text

type CollisionSuffix = Int

data Collision
    = NoCollision
    | Collision CollisionSuffix
    | UnknownCollision -- we have a collision but unknown suffix (inside hole result)
    deriving (Show)

data TagText = TagText
    { _ttText :: Text
    , _ttCollision :: Collision
    } deriving (Show)

data StoredName o = StoredName
    { _snProp :: Property o Text
    , _snDisplayText :: TagText
    , _snTagCollision :: Collision
    }

data Name o
    = AutoGenerated Text
    | Stored (StoredName o)
    | Unnamed CollisionSuffix

visible :: Name o -> (TagText, Collision)
visible (Stored (StoredName _ disp tagCollision)) = (disp, tagCollision)
visible (AutoGenerated name) = (TagText name NoCollision, NoCollision)
visible (Unnamed suffix) = (TagText "Unnamed" NoCollision, Collision suffix)

Lens.makeLenses ''StoredName
Lens.makeLenses ''TagText
Lens.makePrisms ''Collision
Lens.makePrisms ''Name

instance Show (Name o) where
    show (AutoGenerated text) = unwords ["(AutoName", show text, ")"]
    show (Unnamed suffix) = unwords ["(Unnamed", show suffix, ")"]
    show (Stored (StoredName _ disp collision)) =
        unwords ["(StoredName", show disp, show collision, ")"]

instance HasPrecedence (Name o) where
    precedence name =
        visible name ^? _1 . ttText . Lens.ix 0 . Lens.to precedence & fromMaybe 12
