{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}

module Main where

import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Data.MRUMemo (memoIO)
import           Data.Vector.Vector2 (Vector2(..))
import qualified Graphics.DrawingCombinators as Draw
import           Graphics.UI.Bottle.EventMap as EventMap
import qualified Graphics.UI.Bottle.Main as Main
import           Graphics.UI.Bottle.MetaKey (MetaKey(..), noMods)
import           Graphics.UI.Bottle.Widget (Widget, Size, EventResult, keysEventMap, strongerEvents, respondToCursor)
import qualified Graphics.UI.Bottle.Widgets.EventMapDoc as EventMapDoc
import qualified Graphics.UI.Bottle.Widgets.TextView as TextView
import           Graphics.UI.Bottle.Zoom (Zoom)
import qualified Graphics.UI.Bottle.Zoom as Zoom
import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.UI.GLFW.Utils as GLFWUtils

import           Prelude.Compat

openFont :: Size -> IO Draw.Font
openFont size =
    Draw.openFont (min 100 (realToFrac (size ^. _2))) "fonts/DejaVuSans.ttf"

main :: IO ()
main =
    do
        win <- GLFWUtils.createWindow "Hello World" Nothing (Vector2 800 400)
        addHelp <- EventMapDoc.makeToggledHelpAdder EventMapDoc.HelpNotShown
        cachedOpenFont <- memoIO openFont
        Main.mainLoopWidget win (hello cachedOpenFont addHelp) Main.defaultOptions
    & GLFWUtils.withGLFW

hello ::
    Functor m =>
    (Size -> IO Draw.Font) ->
    (EventMapDoc.Config -> Size -> Widget (m EventResult) ->
     IO (Widget (m EventResult))) ->
    Zoom -> Size -> IO (Widget (m EventResult))
hello getFont addHelp zoom _size =
    do
        sizeFactor <- Zoom.getSizeFactor zoom
        font <- getFont (sizeFactor * 20)
        TextView.makeWidget (TextView.whiteText font) "Hello World!" ["hello"]
            & respondToCursor
            & strongerEvents quitEventMap
            & addHelp (EventMapDoc.defaultConfig font) size

quitEventMap :: Functor f => EventMap (f EventResult)
quitEventMap =
    keysEventMap
    [MetaKey noMods GLFW.Key'Q] (EventMap.Doc ["Quit"])
    (error "Quit")
