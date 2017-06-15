module Read exposing (..)

import Dict exposing (Dict)
import Html exposing (Html)
import Html.Events
import Http
import Json.Decode as Decode
import Kintail.InputWidget as InputWidget
import OpenSolid.Step as Step
import OpenSolid.Step.Parse as Parse
import Process
import RemoteData exposing (RemoteData)
import Task exposing (Task)
import Time exposing (Time)


type StepFile
    = Unparsed String
    | Parsed ( Time, Dict Int Step.Entity )


type alias Model =
    { fileName : String
    , stepData : RemoteData String StepFile
    }


type Msg
    = FileNameEdited String
    | LoadRequested
    | DataReceived String
    | LoadFailed
    | FileParsed ( Time, Dict Int Step.Entity )
    | ParseFailed String


init : ( Model, Cmd Msg )
init =
    ( { fileName = "", stepData = RemoteData.NotAsked }, Cmd.none )


parse : String -> Task String ( Time, Dict Int Step.Entity )
parse string =
    Process.sleep (0.1 * Time.second)
        |> Task.andThen
            (\() ->
                Time.now
                    |> Task.andThen
                        (\startTime ->
                            case Parse.file string of
                                Ok ( header, entities ) ->
                                    Time.now
                                        |> Task.map
                                            (\finishTime ->
                                                ( finishTime - startTime
                                                , entities
                                                )
                                            )

                                Err (Parse.ParseError message) ->
                                    Task.fail
                                        ("Parse error: " ++ message)

                                Err (Parse.NonexistentEntity id) ->
                                    Task.fail
                                        ("Nonexistent entity with id "
                                            ++ toString id
                                            ++ " referenced"
                                        )

                                Err (Parse.CircularReference chain) ->
                                    Task.fail
                                        ("Circular reference detected: "
                                            ++ toString chain
                                        )
                        )
            )


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        FileNameEdited fileName ->
            ( { fileName = fileName, stepData = RemoteData.NotAsked }
            , Cmd.none
            )

        LoadRequested ->
            let
                request =
                    Http.request
                        { method = "GET"
                        , headers = [ Http.header "Accept" "text/plain" ]
                        , url = model.fileName
                        , body = Http.emptyBody
                        , expect = Http.expectString
                        , timeout = Nothing
                        , withCredentials = False
                        }

                handleResult result =
                    case result of
                        Ok string ->
                            DataReceived string

                        Err _ ->
                            LoadFailed
            in
            ( { model | stepData = RemoteData.Loading }
            , Http.send handleResult request
            )

        DataReceived string ->
            let
                handleResult result =
                    case result of
                        Ok tuple ->
                            FileParsed tuple

                        Err message ->
                            ParseFailed message

                parseCmd =
                    Task.attempt handleResult (parse string)
            in
            ( { model | stepData = RemoteData.Success (Unparsed string) }
            , parseCmd
            )

        LoadFailed ->
            ( { model | stepData = RemoteData.Failure "Could not load file" }
            , Cmd.none
            )

        FileParsed tuple ->
            ( { model | stepData = RemoteData.Success (Parsed tuple) }
            , Cmd.none
            )

        ParseFailed message ->
            ( { model | stepData = RemoteData.Failure message }
            , Cmd.none
            )


view : Model -> Html Msg
view model =
    Html.div []
        [ Html.div []
            [ InputWidget.lineEdit [] model.fileName |> Html.map FileNameEdited
            , Html.button [ Html.Events.onClick LoadRequested ]
                [ Html.text "Load" ]
            ]
        , Html.div []
            (case model.stepData of
                RemoteData.NotAsked ->
                    [ Html.text "" ]

                RemoteData.Loading ->
                    [ Html.text "Loading..." ]

                RemoteData.Failure message ->
                    [ Html.text message ]

                RemoteData.Success stepData ->
                    case stepData of
                        Unparsed _ ->
                            [ Html.text "Parsing..." ]

                        Parsed ( time, entities ) ->
                            [ Html.text
                                (toString (Dict.size entities)
                                    ++ " entities, parsed in "
                                    ++ toString (Time.inSeconds time)
                                    ++ " seconds"
                                )
                            ]
            )
        ]


main : Program Never Model Msg
main =
    Html.program
        { init = init
        , update = update
        , view = view
        , subscriptions = always Sub.none
        }
