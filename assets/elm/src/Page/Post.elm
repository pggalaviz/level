module Page.Post exposing (Model, Msg(..), consumeEvent, init, receivePresenceState, setup, subscriptions, teardown, title, update, view)

import Component.Post
import Connection
import Event exposing (Event)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Lazy exposing (Lazy(..))
import ListHelpers exposing (insertUniqueBy, removeBy)
import Mutation.RecordPostView as RecordPostView
import Presence exposing (PresenceList)
import Query.PostInit as PostInit
import Reply exposing (Reply)
import Repo exposing (Repo)
import Route exposing (Route)
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import Task exposing (Task)
import TaskHelpers
import Time exposing (Posix, Zone, every)
import View.Helpers exposing (displayName)
import View.Layout exposing (spaceLayout)
import View.PresenceList



-- MODEL


type alias Model =
    { viewer : SpaceUser
    , space : Space
    , bookmarks : List Group
    , post : Component.Post.Model
    , now : ( Zone, Posix )
    , currentViewers : Lazy PresenceList
    }



-- PAGE PROPERTIES


title : Repo -> Model -> String
title repo { viewer } =
    let
        userData =
            Repo.getSpaceUser repo viewer

        name =
            displayName userData
    in
    "View post from " ++ name


viewingTopic : Model -> String
viewingTopic { post } =
    "posts:" ++ post.id



-- LIFECYCLE


init : String -> String -> Session -> Task Session.Error ( Session, Model )
init spaceSlug postId session =
    session
        |> PostInit.request spaceSlug postId
        |> TaskHelpers.andThenGetCurrentTime
        |> Task.andThen buildModel


buildModel : ( ( Session, PostInit.Response ), ( Zone, Posix ) ) -> Task Session.Error ( Session, Model )
buildModel ( ( session, { viewer, space, bookmarks, post } ), now ) =
    Task.succeed ( session, Model viewer space bookmarks post now NotLoaded )


setup : Session -> Model -> Cmd Msg
setup session ({ post } as model) =
    Cmd.batch
        [ Cmd.map PostComponentMsg (Component.Post.setup post)
        , recordView session model
        , Presence.join (viewingTopic model)
        ]


teardown : Model -> Cmd Msg
teardown ({ post } as model) =
    Cmd.batch
        [ Cmd.map PostComponentMsg (Component.Post.teardown post)
        , Presence.leave (viewingTopic model)
        ]


recordView : Session -> Model -> Cmd Msg
recordView session { space, post } =
    let
        { nodes } =
            Connection.last 1 post.replies

        maybeReplyId =
            case nodes of
                [ lastReply ] ->
                    Just (Reply.getId lastReply)

                _ ->
                    Nothing
    in
    session
        |> RecordPostView.request (Space.getId space) post.id maybeReplyId
        |> Task.attempt ViewRecorded



-- UPDATE


type Msg
    = PostComponentMsg Component.Post.Msg
    | ViewRecorded (Result Session.Error ( Session, RecordPostView.Response ))
    | Tick Posix
    | SetCurrentTime Posix Zone
    | NoOp


update : Msg -> Session -> Model -> ( ( Model, Cmd Msg ), Session )
update msg session ({ post } as model) =
    case msg of
        PostComponentMsg componentMsg ->
            let
                ( ( newPost, cmd ), newSession ) =
                    Component.Post.update componentMsg (Space.getId model.space) session post
            in
            ( ( { model | post = newPost }
              , Cmd.map PostComponentMsg cmd
              )
            , newSession
            )

        ViewRecorded (Ok ( newSession, _ )) ->
            noCmd newSession model

        ViewRecorded (Err Session.Expired) ->
            redirectToLogin session model

        ViewRecorded (Err _) ->
            noCmd session model

        Tick posix ->
            ( ( model, Task.perform (SetCurrentTime posix) Time.here ), session )

        SetCurrentTime posix zone ->
            { model | now = ( zone, posix ) }
                |> noCmd session

        NoOp ->
            noCmd session model


noCmd : Session -> Model -> ( ( Model, Cmd Msg ), Session )
noCmd session model =
    ( ( model, Cmd.none ), session )


redirectToLogin : Session -> Model -> ( ( Model, Cmd Msg ), Session )
redirectToLogin session model =
    ( ( model, Route.toLogin ), session )



-- INBOUND EVENTS


consumeEvent : Event -> Model -> ( Model, Cmd Msg )
consumeEvent event model =
    case event of
        Event.GroupBookmarked group ->
            ( { model | bookmarks = insertUniqueBy Group.getId group model.bookmarks }, Cmd.none )

        Event.GroupUnbookmarked group ->
            ( { model | bookmarks = removeBy Group.getId group model.bookmarks }, Cmd.none )

        Event.ReplyCreated reply ->
            let
                ( newPost, cmd ) =
                    Component.Post.handleReplyCreated reply model.post
            in
            ( { model | post = newPost }
            , Cmd.map PostComponentMsg cmd
            )

        _ ->
            ( model, Cmd.none )


receivePresenceState : Presence.Topic -> PresenceList -> Model -> ( Model, Cmd Msg )
receivePresenceState topic list model =
    if topic == viewingTopic model then
        ( { model | currentViewers = Loaded list }, Cmd.none )

    else
        ( model, Cmd.none )



-- SUBSCRIPTIONS


subscriptions : Sub Msg
subscriptions =
    every 1000 Tick



-- VIEW


view : Repo -> Maybe Route -> Model -> Html Msg
view repo maybeCurrentRoute model =
    spaceLayout repo
        model.viewer
        model.space
        model.bookmarks
        maybeCurrentRoute
        [ div [ class "mx-56" ]
            [ div [ class "mx-auto max-w-90 leading-normal" ]
                [ postView repo model.space model.viewer model.now model.post
                , sidebarView repo model
                ]
            ]
        ]


postView : Repo -> Space -> SpaceUser -> ( Zone, Posix ) -> Component.Post.Model -> Html Msg
postView repo space currentUser now component =
    div [ class "pt-6" ]
        [ Component.Post.view repo space currentUser now component
            |> Html.map PostComponentMsg
        ]


sidebarView : Repo -> Model -> Html Msg
sidebarView repo model =
    let
        listView =
            case model.currentViewers of
                Loaded state ->
                    View.PresenceList.view repo state

                NotLoaded ->
                    div [ class "pb-4 text-sm" ] [ text "Loading..." ]
    in
    div [ class "fixed pin-t pin-r w-56 mt-3 py-2 px-6 border-l min-h-half" ]
        [ h3 [ class "mb-2 text-base font-extrabold" ] [ text "Who’s Here" ]
        , listView
        ]
