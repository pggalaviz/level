module Page.Room
    exposing
        ( Model
        , Msg
        , fetchRoom
        , buildModel
        , loaded
        , view
        , update
        , receiveMessage
        , subscriptions
        )

{-| Viewing an particular room.
-}

import Task exposing (Task)
import Http
import Json.Decode as Decode
import Html exposing (..)
import Html.Events exposing (on, onWithOptions, defaultOptions, onInput, onClick)
import Html.Attributes exposing (..)
import Dom exposing (focus)
import Dom.Scroll
import Date
import Time exposing (Time, second, millisecond)
import Data.User exposing (User, UserConnection)
import Data.Room exposing (Room, RoomMessageConnection, RoomMessageEdge, RoomMessage)
import Data.Session exposing (Session)
import Query.Room
import Query.RoomMessages
import Mutation.CreateRoomMessage as CreateRoomMessage
import Ports


-- MODEL


type alias Model =
    { room : Room
    , messages : RoomMessageConnection
    , users : UserConnection
    , composerBody : String
    , isSubmittingMessage : Bool
    , isFetchingMessages : Bool
    , messagesScrollPosition : Maybe Ports.ScrollPosition
    }


{-| Builds a Task to fetch a room by slug.
-}
fetchRoom : Session -> String -> Task Http.Error Query.Room.Response
fetchRoom session slug =
    Query.Room.request session.apiToken (Query.Room.Params slug)
        |> Http.toTask


{-| Builds a model for this page based on the response from initial page request.
-}
buildModel : Query.Room.Data -> Model
buildModel data =
    Model data.room data.messages data.users "" False False Nothing


{-| Builds the task to perform post-page load.
-}
loaded : Cmd Msg
loaded =
    Cmd.batch
        [ scrollToBottom "messages"
        , focusOnComposer
        ]


{-| Append a new message to the room message connection when it is received.
-}
receiveMessage : RoomMessage -> Model -> ( Model, Cmd Msg )
receiveMessage message model =
    let
        pageInfo =
            model.messages.pageInfo

        edges =
            RoomMessageEdge message :: model.messages.edges

        newMessages =
            RoomMessageConnection edges pageInfo
    in
        ( { model | messages = newMessages }, scrollToBottom "messages" )



-- UPDATE


type Msg
    = ComposerBodyChanged String
    | MessageSubmitted
    | MessageSubmitResponse (Result Http.Error RoomMessage)
    | MessagesFetched (Result Http.Error Query.RoomMessages.Response)
    | Tick Time
    | ScrollPositionReceived Decode.Value
    | NoOp


update : Msg -> Session -> Model -> ( Model, Cmd Msg )
update msg session model =
    case msg of
        ComposerBodyChanged newBody ->
            ( { model | composerBody = newBody }, Cmd.none )

        MessageSubmitted ->
            let
                params =
                    CreateRoomMessage.Params model.room model.composerBody

                request =
                    CreateRoomMessage.request session.apiToken params
            in
                if isSendDisabled model then
                    ( model, Cmd.none )
                else
                    ( { model | isSubmittingMessage = True }
                    , Http.send MessageSubmitResponse request
                    )

        MessageSubmitResponse (Ok message) ->
            ( { model
                | isSubmittingMessage = False
                , composerBody = ""
              }
            , Cmd.none
            )

        MessageSubmitResponse (Err _) ->
            -- TODO: implement this
            ( model, Cmd.none )

        Tick _ ->
            ( model, Ports.getScrollPosition "messages" )

        ScrollPositionReceived value ->
            let
                result =
                    Decode.decodeValue Ports.scrollPositionDecoder value
            in
                case result of
                    Ok position ->
                        case position.id of
                            "messages" ->
                                let
                                    modelWithPosition =
                                        { model | messagesScrollPosition = Just position }
                                in
                                    if position.fromTop <= 200 then
                                        fetchPreviousMessages session modelWithPosition
                                    else
                                        ( modelWithPosition, Cmd.none )

                            _ ->
                                ( model, Cmd.none )

                    Err _ ->
                        ( model, Cmd.none )

        MessagesFetched (Ok response) ->
            case response of
                Query.RoomMessages.Found { messages } ->
                    let
                        edges =
                            model.messages.edges

                        anchorId =
                            case List.head (List.reverse edges) of
                                Just edge ->
                                    messageId edge

                                Nothing ->
                                    ""

                        offset =
                            case model.messagesScrollPosition of
                                Just position ->
                                    position.fromTop

                                Nothing ->
                                    0

                        pageInfo =
                            model.messages.pageInfo

                        newEdges =
                            List.append edges messages.edges

                        newPageInfo =
                            { pageInfo
                                | hasNextPage = messages.pageInfo.hasNextPage
                                , endCursor = messages.pageInfo.endCursor
                            }

                        newConnection =
                            RoomMessageConnection newEdges newPageInfo

                        scrollParams =
                            Ports.ScrollParams "messages" anchorId offset
                    in
                        ( { model
                            | messages = newConnection
                            , isFetchingMessages = False
                          }
                        , Ports.scrollTo scrollParams
                        )

                Query.RoomMessages.NotFound ->
                    ( { model | isFetchingMessages = False }, Cmd.none )

        MessagesFetched (Err _) ->
            ( { model | isFetchingMessages = False }, Cmd.none )

        NoOp ->
            ( model, Cmd.none )


{-| Scrolls the messages container to the most recent message.
-}
scrollToBottom : String -> Cmd Msg
scrollToBottom id =
    Task.attempt (always NoOp) <| Dom.Scroll.toBottom id


{-| Sets focus to the composer body textarea.
-}
focusOnComposer : Cmd Msg
focusOnComposer =
    Task.attempt (always NoOp) <| focus "composer-body-field"


{-| Executes a query for previous messages, updates the model to a fetching
state, and returns a model and command tuple.
-}
fetchPreviousMessages : Session -> Model -> ( Model, Cmd Msg )
fetchPreviousMessages session model =
    case model.messages.pageInfo.endCursor of
        Just endCursor ->
            if model.messages.pageInfo.hasNextPage == True && model.isFetchingMessages == False then
                let
                    params =
                        Query.RoomMessages.Params model.room.id endCursor 20

                    request =
                        Query.RoomMessages.request session.apiToken params
                in
                    ( { model | isFetchingMessages = True }, Http.send MessagesFetched request )
            else
                ( model, Cmd.none )

        Nothing ->
            ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every (500 * millisecond) Tick
        , Ports.scrollPositionReceived ScrollPositionReceived
        ]



-- VIEW


onEnter : Msg -> Attribute Msg
onEnter msg =
    let
        options =
            { defaultOptions | preventDefault = True }

        codeAndShift : Decode.Decoder ( Int, Bool )
        codeAndShift =
            Decode.map2 (\a b -> ( a, b ))
                Html.Events.keyCode
                (Decode.field "shiftKey" Decode.bool)

        isEnter : ( Int, Bool ) -> Decode.Decoder Msg
        isEnter ( code, shiftKey ) =
            if code == 13 && shiftKey == False then
                Decode.succeed msg
            else
                Decode.fail "not ENTER"
    in
        onWithOptions "keydown" options (Decode.andThen isEnter codeAndShift)


view : Model -> Html Msg
view model =
    div [ id "main", class "main main--room" ]
        [ div [ class "page-head" ]
            [ h2 [ class "page-head__name" ] [ text model.room.name ]
            , p [ class "page-head__description" ] [ text model.room.description ]
            ]
        , renderMessages model.messages
        , div [ class "composer" ]
            [ div [ class "composer__body" ]
                [ textarea
                    [ id "composer-body-field"
                    , class "text-field text-field--muted textarea composer__body-field"
                    , onInput ComposerBodyChanged
                    , onEnter MessageSubmitted
                    , readonly (isComposerReadOnly model)
                    , value model.composerBody
                    ]
                    []
                ]
            , div [ class "composer__controls" ]
                [ button
                    [ class "button button--primary"
                    , disabled (isSendDisabled model)
                    , onClick MessageSubmitted
                    ]
                    [ text "Send Message" ]
                ]
            ]
        ]


renderMessages : RoomMessageConnection -> Html Msg
renderMessages connection =
    div [ id "messages", class "messages" ] (List.map renderMessage (List.reverse connection.edges))


renderMessage : RoomMessageEdge -> Html Msg
renderMessage edge =
    div [ id (messageId edge), class "message" ]
        [ div [ class "message__avatar" ] []
        , div [ class "message__contents" ]
            [ div [ class "message__head" ]
                [ span [ class "message__name" ] [ text (Data.User.displayName edge.node.user) ]
                , span [ class "message__middot" ] [ text "·" ]
                , span [ class "message__timestamp" ] [ text (formatTime edge.node.insertedAt) ]
                ]
            , div [ class "message__body" ] [ text edge.node.body ]
            ]
        ]


{-| Takes an edge from a room messages connection returns the DOM node ID for
the message.
-}
messageId : RoomMessageEdge -> String
messageId edge =
    "message-" ++ edge.node.id


{-| Determines if the "Send Message" button should be disabled.

    isSendDisabled { composerBody = "" } == True
    isSendDisabled { composerBody = "I have some text" } == False
    isSendDisabled { isSubmittingMessage = True } == False

-}
isSendDisabled : Model -> Bool
isSendDisabled model =
    model.composerBody == "" || (isComposerReadOnly model)


{-| Determines if the composer textarea should be read-only.

    isSendDisabled { composerBody = "" } == True
    isSendDisabled { composerBody = "I have some text" } == False
    isSendDisabled { isSubmittingMessage = True } == False

-}
isComposerReadOnly : Model -> Bool
isComposerReadOnly model =
    model.isSubmittingMessage == True


{-| Converts a Time into a human-friendly HH:MMam time string.

    isSendDisabled 1510444158581 == "11:10am"

-}
formatTime : Time -> String
formatTime time =
    let
        date =
            Date.fromTime time

        hour =
            Date.hour date

        minute =
            Date.minute date

        meridian =
            if hour < 12 then
                "am"
            else
                "pm"
    in
        (formatHour hour) ++ ":" ++ (formatMinute minute) ++ " " ++ meridian


{-| Convert hour value to 12-hour time string.

    formatHour 0 == "12"
    formatHour 1 == "1"
    formatHour 14 == "2"

-}
formatHour : Int -> String
formatHour value =
    if value == 0 || value == 12 then
        "12"
    else
        toString <| value % 12


{-| Convert minute value to a string for using in HH:MM timestamps.

    formatMinute 0 == "00"
    formatMinute 9 == "09"
    formatMinute 14 == "14"

-}
formatMinute : Int -> String
formatMinute value =
    if value < 10 then
        "0" ++ (toString value)
    else
        toString value
