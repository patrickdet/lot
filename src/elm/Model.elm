module Model (Model, Action, Action(..), Focus(..), empty, isEditing, update, decode) where

import Sheet
import Cell exposing (Cell(..))
import Addr exposing (Addr, Direction(..))
import Char
import String
import Maybe exposing (andThen)
import Task
import Effects
import Solver
import Constraint exposing (Context(..))
import Tableau

import Http
import History
import Json.Decode as Decode exposing ((:=))
import Json.Encode as Encode

type Focus = Sheet | Tableau

type alias Editing =
  { quick : Bool  -- if initiated by a keypress
  , initialValue : String
  }

type alias Model = 
  { focus : Focus
  , sheet : Sheet.Sheet
  , selection : Addr
  -- If Nothing, no cell is being edited. If Just, currently selected cell is being edited
  , editing : Maybe Editing
  , tableau: Tableau.Tableau
  , domain: Solver.Domain
  , solver: Maybe (Result String Solver.Solver) -- available when z3 solver loads successfully (see LoadSolver action)

  -- When true, model is unsatisfiable
  , unsat: Bool
  -- This holds last satisfiable model, if any
  , lastSat: Maybe (Sheet.Sheet, Tableau.Tableau, Solver.Domain)
  }

empty : Model
empty =
  { focus = Sheet
  , sheet = Sheet.initialize 5 5
  , selection = Addr.fromColRow 0 0
  , editing = Nothing
  , tableau = Tableau.empty
  , domain = Solver.Reals
  , solver = Nothing
  , unsat = False
  , lastSat = Nothing
  }

isEditing : Model -> Bool
isEditing model =
  model.editing /= Nothing

type Action
  = InputArrows { x: Int, y: Int, alt: Bool }
  | InputKeypress Char.KeyCode
  | SwitchFocus Focus
  ---
  | LoadSolver (Result String Solver.Solver)
  | Solve
  | ChangeDomain Solver.Domain
  | AddConstraint String
  | DropConstraint Int
  | Undo
  ---
  | Select Addr -- Direct selection of the cell at given address
  | Move Addr.Direction -- Keyboard movement in this relative direction
  | Insert Addr.Direction -- Insert row/col in this direction
  | Edit (Maybe Char) -- Start editing. Can be triggerered by a character pressed by user (Just Char) or by doubleclick (Nothing)
  | Commit Addr String
  | Cancel
  | Clear -- updates selected cell to an empty cell
  ---
  | Save -- saves sheet and pushes the new url to navigation stack if successful
  | SaveResult (Result Http.Error String)
  ---
  | Nop

update : Action -> Model -> (Model, Effects.Effects Action)
update action model =
  let
    action =
      case action of 
        LoadSolver _ -> action -- solver object can't be shown w/o blowing the stack
        _ -> Debug.log "update" action 
    noFx model =
      (model, Effects.none)
    nop =
      noFx model
    anotherActionFx action model = 
      (model, Task.succeed action |> Effects.task)
  in
  case action of
    Nop ->
      nop
    Save ->
      let
        requestTask =
          Http.post
            ("ok" := Decode.string)
            "/pickle"
            (encode model |> Http.string)
          |> Task.toResult
          |> Task.map SaveResult
          |> Effects.task
      in
      (model, requestTask)
    SaveResult r ->
      case r of
        Err err ->
          let _ = Debug.log "Save failed" err
          in
          nop
        Ok slug ->
          ( model
          , History.replacePath ("/" ++ slug) |> Task.map (always Nop) |> Effects.task
          )
    SwitchFocus f ->
      noFx
        { model | 
          focus = f
        }
    InputArrows a ->
      case model.focus of
        Sheet ->
          case (Addr.xy2dir a, Maybe.map (.quick) model.editing) of
            (Just Left, Just False) -> 
              nop
            (Just Right, Just False) ->
              nop
            (Just dir, _) ->
              anotherActionFx (if a.alt then Insert dir else Move dir) model
            (Nothing, _) ->
              nop
        Tableau ->
          nop
    InputKeypress key ->
      case model.focus of
        Sheet ->
          case (isEditing model, key) of
            (_, 0) ->
              nop
            (True, _) ->
              nop
            (False, 8) ->
              anotherActionFx Clear model
            (False, _) ->
              -- Enter should be like double-click
              anotherActionFx (Edit <| if key == 13 then Nothing else Just <| Char.fromCode key) model
        Tableau ->
          nop
    ---
    LoadSolver result ->
      noFx
        { model |
          solver = Just result
        }
    Solve -> 
      case model.solver of
        Just (Ok solver) ->  
          case Solver.solve model.sheet model.tableau model.domain solver of
            Ok solution ->
              noFx
                { model
                | sheet = solution
                , unsat = False
                , lastSat = Just (model.sheet, model.tableau, model.domain)
                }
            Err error ->
              noFx
                { model 
                | unsat = True
                }
        _ ->
          let _ = Debug.log "No solver available" in nop
    AddConstraint str ->
      case Tableau.parse GlobalContext str of
        Ok t ->
          anotherActionFx Solve
            { model | 
              tableau = Tableau.append model.tableau t
            }
        Err error ->
          nop
    DropConstraint i ->
      anotherActionFx Solve 
        { model |
          tableau = Tableau.dropAt i model.tableau
        }
    ChangeDomain d ->
      anotherActionFx Solve
        { model |
          domain = d
        }
    Undo ->
      case (model.unsat, model.lastSat) of
        (False, _) -> 
          nop
        (True, Nothing) ->
          let _ = Debug.log "Can't undo - no satisfiable model known" in nop
        (True, Just (sheet, tableau, domain)) ->
          anotherActionFx Solve 
            { model 
            | sheet = sheet
            , tableau = tableau
            , domain = domain
            }
    ---
    Clear ->
      let
        clearSheet = Sheet.update model.selection (always EmptyCell) model.sheet
      in
      case Sheet.get model.selection model.sheet of
        Just (ResultCell _) ->
          -- Do not allow clearing result cells
          nop
        _ ->
          -- otherwise, clear the cell but don't reevaluate
          noFx { model | sheet = clearSheet }
    Select addr ->
      noFx 
        { model
        | focus = Sheet
        , selection = addr
        }
    Commit addr str ->
      let
        cell = 
          Sheet.get addr model.sheet
        id = 
          Addr.toIdentifier addr
        (newCell, newTableau) =
          case String.trim str |> String.isEmpty of
            True ->
              (EmptyCell, [])
            False ->
              case Tableau.parse (CellContext id) str of
                Err _ ->
                  (TextCell str, [])
                Ok t ->
                  (ResultCell Nothing, t)
        reevaluate = 
          case (cell, newCell) of
            (Just (ResultCell _), _) -> True
            (_ , ResultCell _) -> True
            _ -> False
      in
        (if reevaluate then anotherActionFx Solve else noFx)
        { model
          | editing = Nothing
          , sheet = Sheet.update addr (always newCell) model.sheet
          , selection =
              if addr == model.selection then
                -- Enter key was pressed, advance selection by one
                Sheet.move model.selection Down model.sheet
              else
                model.selection
          , tableau =
              if reevaluate then
                model.tableau 
                |> Tableau.dropCell id
                |> flip Tableau.append newTableau
              else
                model.tableau
        }
    Cancel ->
      noFx 
        { model | 
          editing = Nothing
        }
    Edit char ->
      let
        id =
          Addr.toIdentifier model.selection
        editing =
          case char of
            Nothing -> 
              { quick = False
              , initialValue = 
                  Sheet.get model.selection model.sheet
                  |> Maybe.map (\cell ->
                        case cell of 
                          TextCell t -> t
                          ResultCell _ -> Tableau.source id model.tableau
                          EmptyCell -> ""
                    )
                  |> Maybe.withDefault ""
              }
            Just c ->
              { quick = True
              , initialValue = String.fromChar c
              }
      in
      noFx
        { model | 
          editing = Just editing
        }
    Move direction ->
      noFx
        { model |
          selection = Sheet.move model.selection direction model.sheet,
          editing = Nothing
        }
    Insert direction ->
      let
        sheet = 
          if direction == Left || direction == Right  then
            Sheet.insertCol (Addr.col model.selection) model.sheet
          else
            Sheet.insertRow (Addr.row model.selection) model.sheet
        selection =
          if direction == Right || direction == Down then
            Sheet.move model.selection direction sheet
          else
            model.selection
      in
      noFx
        { model |
          selection = selection,
          sheet = sheet 
        }

-- Encoding/decoding

decode : String -> Result.Result String Model
decode str = 
  let
    domainFromString str =
      if str == "ints" then Solver.Ints else Solver.Reals
    build sheet tableau domain =
      let _ = Debug.log "Decoded" (sheet,tableau, domain)
      in
      { empty
      | sheet = sheet
      , tableau = tableau
      , domain = domain
      }
    decoder =
      Decode.object3
        build
        ("sheet" := Sheet.decoder)
        ("tableau" := Tableau.decoder)
        ("domain" := Decode.object1 domainFromString Decode.string)
  in
    Decode.decodeString decoder str

encode : Model -> String
encode model =
  let
    encoder =
      Encode.object
        [ ("sheet", Sheet.encode model.sheet)
        , ("tableau", Tableau.encode model.tableau)
        , ("domain",
            Encode.string 
            (case model.domain of
              Solver.Ints -> "ints"
              Solver.Reals -> "reals"
            )
          )
        ]
  in
    Encode.encode 0 encoder