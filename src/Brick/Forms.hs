{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
module Brick.Forms
  ( FormEntry
  , FormEntryState
  , Form
  -- * Working with Forms
  , newForm
  , renderForm
  , defaultFormRenderer
  , handleFormEvent
  , formFocus
  , formState
  -- * Form entry types
  , editEntry
  , editShowable
  , editPassword
  -- * Attributes
  , invalidFormInputAttr
  )
where

import Graphics.Vty
import Data.Monoid
import Data.Maybe (isJust)

import Brick
import Brick.Focus
import Brick.Widgets.Edit

import qualified Data.Text as T
import Text.Read (readMaybe)

import Lens.Micro

data FormEntry a b e n =
    FormEntry { _formEntryValidate    :: b -> Maybe a
              , _formEntryRender      :: Bool -> b -> Widget n
              , _formEntryHandleEvent :: BrickEvent n e -> b -> EventM n b
              }

data FormEntryState s e n where
    FormEntryState :: (Named b n) =>
                      { formEntryName  :: n
                      , formEntryState :: b
                      , formEntry      :: FormEntry a b e n
                      , formEntryLens  :: Lens' s a
                      } -> FormEntryState s e n

data Form s e n =
    Form { formEntries      :: [FormEntryState s e n]
         , formFocus        :: FocusRing n
         , formState        :: s
         , formRenderHelper :: Form s e n -> n -> Widget n -> Widget n
         }

defaultFormRenderer :: (Show n) => Form s e n -> n -> Widget n -> Widget n
defaultFormRenderer f n w =
    let allNames = formEntryName <$> formEntries f
        maxLength = 1 + (maximum $ length <$> show <$> allNames)
        p = maxLength - length (show n)
        label = padRight (Pad p) $ str $ show n <> ":"
    in label <+> w

newForm :: (Form s e n -> n -> Widget n -> Widget n)
        -> [s -> FormEntryState s e n]
        -> s
        -> Form s e n
newForm helper mkEs s =
    let es = mkEs <*> pure s
    in Form { formEntries      = es
            , formFocus        = focusRing $ formEntryName <$> es
            , formState        = s
            , formRenderHelper = helper
            }

editEntry :: (Ord n, Show n)
          => Lens' s a
          -> n
          -> Maybe Int
          -> (a -> T.Text)
          -> ([T.Text] -> Maybe a)
          -> ([T.Text] -> Widget n)
          -> (Widget n -> Widget n)
          -> s
          -> FormEntryState s e n
editEntry stLens n limit ini val renderText wrapEditor initialState =
    let initVal = mk $ initialState ^. stLens
        mk = editor n limit . ini
        handleEvent (VtyEvent e) ed = handleEditorEvent e ed
        handleEvent _ ed = return ed

    in FormEntryState { formEntryName  = getName initVal
                      , formEntryState = initVal
                      , formEntry      = FormEntry (val . getEditContents)
                                                   (\b e -> wrapEditor $ renderEditor renderText b e)
                                                   handleEvent
                      , formEntryLens  = stLens
                      }

editShowable :: (Ord n, Show n, Read a, Show a)
             => Lens' s a
             -> n
             -> s
             -> FormEntryState s e n
editShowable stLens n =
    let ini = T.pack . show
        val = readMaybe . T.unpack . T.intercalate "\n"
        limit = Just 1
        renderText = txt . T.unlines
    in editEntry stLens n limit ini val renderText id

editPassword :: (Ord n, Show n)
             => Lens' s T.Text
             -> n
             -> s
             -> FormEntryState s e n
editPassword stLens n =
    let ini = id
        val = Just . T.concat
        limit = Just 1
        renderText = toPassword
    in editEntry stLens n limit ini val renderText id

toPassword :: [T.Text] -> Widget a
toPassword s = txt $ T.replicate (T.length $ T.concat s) "*"

formAttr :: AttrName
formAttr = "brickForm"

invalidFormInputAttr :: AttrName
invalidFormInputAttr = formAttr <> "invalidInput"

renderForm :: (Eq n) => Form s e n -> Widget n
renderForm f@(Form es fr _ helper) =
    vBox $ renderFormEntry (helper f) fr <$> es

renderFormEntry :: (Eq n)
                => (n -> Widget n -> Widget n)
                -> FocusRing n
                -> FormEntryState s e n
                -> Widget n
renderFormEntry helper fr (FormEntryState n st (FormEntry valid renderFunc _) _) =
    let maybeInvalid = if isJust $ valid st then id else forceAttr invalidFormInputAttr
        w = maybeInvalid (withFocusRing fr renderFunc st)
    in helper n w

handleFormEvent :: (Eq n) => BrickEvent n e -> Form s e n -> EventM n (Form s e n)
handleFormEvent (VtyEvent (EvKey (KChar '\t') [])) f =
    return $ f { formFocus = focusNext $ formFocus f }
handleFormEvent e f =
    case focusGetCurrent (formFocus f) of
        Nothing -> return f
        Just n  -> handleFormEntryEvent n e f

handleFormEntryEvent :: (Eq n) => n -> BrickEvent n e -> Form s e n -> EventM n (Form s e n)
handleFormEntryEvent n ev f = handle [] (formEntries f)
    where
        handle _ [] = return f
        handle prev (e:es) =
            case e of
                FormEntryState n' st entry@(FormEntry val _ handleFunc) stLens | n == n' -> do
                    nextSt <- handleFunc ev st
                    let newEntry = FormEntryState n' nextSt entry stLens
                    -- If the new state validates, go ahead and update
                    -- the form state with it.
                    case val nextSt of
                        Nothing -> return $ f { formEntries = prev <> [newEntry] <> es }
                        Just valid -> return $ f { formEntries = prev <> [newEntry] <> es
                                                 , formState = formState f & stLens .~ valid
                                                 }

                _ -> handle (prev <> [e]) es
