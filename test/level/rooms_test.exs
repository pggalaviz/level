defmodule Level.RoomsTest do
  use Level.DataCase

  alias Level.Rooms
  alias Level.Spaces

  describe "create_room/2" do
    setup do
      insert_signup()
    end

    test "creates a room and subscription given a valid params",
      %{space: space, user: user} do
      params = valid_room_params()

      {:ok, %{room: room, room_subscription: subscription}} =
        Rooms.create_room(user, params)

      assert room.space_id == space.id
      assert room.creator_id == user.id
      assert room.name == params.name
      assert room.state == "ACTIVE"

      assert subscription.user_id == user.id
      assert subscription.room_id == room.id
    end

    test "returns an error tuple given invalid params",
      %{user: user} do
      params =
        valid_room_params()
        |> Map.put(:name, nil)

      {:error, :room, changeset, _} = Rooms.create_room(user, params)

      assert %Ecto.Changeset{
        errors: [name: {"can't be blank", [validation: :required]}]
      } = changeset
    end
  end

  describe "get_room_subscription/2" do
    setup do
      insert_signup()
    end

    test "returns the subscription if user is subscribed to the room",
      %{user: user} do
      {:ok, %{room: room}} = Rooms.create_room(user, valid_room_params())
      {:ok, subscription} = Rooms.get_room_subscription(room, user)
      assert subscription.room_id == room.id
      assert subscription.user_id == user.id
    end

    test "returns nil if user is not subscribed to the room",
      %{space: space, user: user} do
      {:ok, %{room: room}} = Rooms.create_room(user, valid_room_params())

      # TODO: implement a helper method for adding a user like this
      {:ok, another_user} =
        %Spaces.User{}
        |> Spaces.User.signup_changeset(valid_user_params())
        |> put_change(:space_id, space.id)
        |> put_change(:role, "MEMBER")
        |> Repo.insert()

      assert {:error, _} = Rooms.get_room_subscription(room, another_user)
    end
  end

  describe "get_room/2" do
    setup do
      create_user_and_room()
    end

    test "returns the room if the user has access", %{user: user, room: room} do
      {:ok, %Rooms.Room{id: fetched_room_id}} = Rooms.get_room(user, room.id)
      assert fetched_room_id == room.id
    end

    test "returns the room if the room is public", %{user: user, room: room} do
      Repo.delete_all(Rooms.RoomSubscription) # delete the subscription
      {:ok, %Rooms.Room{id: fetched_room_id}} = Rooms.get_room(user, room.id)
      assert fetched_room_id == room.id
    end

    test "returns an error if room has been deleted", %{user: user, room: room} do
      Rooms.delete_room(room)
      assert {:error, _} = Rooms.get_room(user, room.id)
    end

    test "returns an error if room does not exist", %{user: user, room: room} do
      Repo.delete_all(Rooms.RoomSubscription)
      Repo.delete(room)
      assert {:error, _} = Rooms.get_room(user, room.id)
    end

    test "returns an error if the room is invite-only and user doesn't have access",
      %{user: user, room: room} do
      # TODO: Implement an #update_policy function and use that here
      Repo.update(Ecto.Changeset.change(room, subscriber_policy: "INVITE_ONLY"))
      {:ok, subscription} = Rooms.get_room_subscription(room, user)
      Rooms.delete_room_subscription(subscription)
      assert {:error, _} = Rooms.get_room(user, room.id)
    end
  end

  describe "delete_room/1" do
    setup do
      create_user_and_room()
    end

    test "sets state to deleted", %{room: room} do
      assert {:ok, %Rooms.Room{state: "DELETED"}} = Rooms.delete_room(room)
    end
  end

  describe "delete_room_subscription/1" do
    setup do
      create_user_and_room()
    end

    test "deletes the room subscription record", %{user: user, room: room} do
      {:ok, subscription} = Rooms.get_room_subscription(room, user)
      {:ok, _} = Rooms.delete_room_subscription(subscription)
      assert {:error, _} = Rooms.get_room_subscription(room, user)
    end
  end

  describe "create_message/3" do
    setup do
      create_user_and_room()
    end

    test "creates a message given valid params", %{room: room, user: user} do
      params = valid_room_message_params()
      {:ok, message} = Rooms.create_message(room, user, params)
      assert message.user_id == user.id
      assert message.room_id == room.id
      assert message.body == params.body
    end

    test "returns an error with changeset if invalid",
      %{room: room, user: user} do

      params =
        valid_room_message_params()
        |> Map.put(:body, nil)

      {:error, changeset} = Rooms.create_message(room, user, params)

      assert %Ecto.Changeset{
        errors: [body: {"can't be blank", [validation: :required]}]
      } = changeset
    end
  end

  describe "message_created_payload/2" do
    setup do
      {:ok, %{room: %Rooms.Room{}, message: %Rooms.Message{}}}
    end

    test "builds a GraphQL payload", %{room: room, message: message} do
      assert Rooms.message_created_payload(room, message) == %{
        success: true,
        room: room,
        room_message: message,
        errors: []
      }
    end
  end

  describe "subscribe_to_room/2" do
    setup do
      {:ok, %{user: owner, room: room, space: space}} = create_user_and_room()
      {:ok, another_user} = insert_member(space)
      {:ok, %{owner: owner, room: room, user: another_user}}
    end

    test "creates a room subscription if not already subscribed",
      %{room: room, user: user} do

      {:ok, subscription} = Rooms.subscribe_to_room(room, user)
      assert subscription.user_id == user.id
      assert subscription.room_id == room.id
    end

    test "returns an error if already subscribed",
      %{room: room, owner: owner} do
      {:error, %Ecto.Changeset{errors: errors}} =
        Rooms.subscribe_to_room(room, owner)

      assert errors == [user_id: {"is already subscribed to this room", []}]
    end
  end

  defp create_user_and_room do
    {:ok, %{user: user, space: space}} = insert_signup()
    {:ok, %{room: room}} = Rooms.create_room(user, valid_room_params())
    {:ok, %{user: user, room: room, space: space}}
  end
end