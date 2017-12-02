defmodule Level.Spaces do
  @moduledoc """
  A space is the fundamental organizational unit in Level. Think of a space like
  a "company" or "organization", just more concise and generically-named.

  All users must be related to a particular space, either as the the owner or
  some other role.
  """

  alias Level.Spaces.Space
  alias Level.Spaces.User
  alias Level.Spaces.Registration
  alias Level.Spaces.Invitation
  alias Level.Repo

  @doc """
  Fetches a space by slug and returns `nil` if not found.
  """
  def get_space_by_slug(slug) do
    Repo.get_by(Space, %{slug: slug})
  end

  @doc """
  Fetches a space by slug.

  ## Examples

      # If found, returns the space.
      get_space_by_slug!("level")
      => %Space{slug: "level", ...}

      # Otherwise, raises an `Ecto.NoResultsError` exception.
  """
  def get_space_by_slug!(slug) do
    Repo.get_by!(Space, %{slug: slug})
  end

  @doc """
  Fetches a user by id.

  ## Examples

      # If found, returns the user.
      get_user(123)
      => %User{id: 123, ...}

      # Otherwise, returns `nil`.
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Fetches a user by space and identifier (either email or username).

  ## Examples

      # If found, returns the user.
      get_user_by_identifier(space, "derrick@level.com")
      => %User{...}

      # Otherwise, returns `nil`.
  """
  def get_user_by_identifier(space, identifier) do
    column = if Regex.match?(~r/@/, identifier) do
      :email
    else
      :username
    end

    params = Map.put(%{space_id: space.id}, column, identifier)
    Repo.get_by(User, params)
  end

  @doc """
  Builds a changeset for performing user registration.
  """
  def registration_changeset(struct, params \\ %{}) do
    Registration.changeset(struct, params)
  end

  @doc """
  Performs user registration from a given changeset.

  ## Examples

      # If successful, returns the newly created records.
      register(%Ecto.Changeset{...})
      => {:ok, %{default_room: %{room: room}, space: space, user: user}}

      # Otherwise, returns an error.
      => {:error, failed_operation, failed_value, changes_so_far}
  """
  def register(changeset) do
    changeset
    |> Registration.create_operation()
    |> Repo.transaction()
  end

  @doc """
  Builds a changeset for creating an invitation.
  """
  def create_invitation_changeset(params \\ %{}) do
    Invitation.changeset(%Invitation{}, params)
  end

  @doc """
  Creates an invitation and sends an email to the invited person.
  """
  def create_invitation(changeset) do
    case Repo.insert(changeset) do
      {:ok, invitation} ->
        invitation =
          invitation
          |> Repo.preload([:space, :invitor])

        invitation
        |> LevelWeb.Email.invitation_email()
        |> Level.Mailer.deliver_later()

        {:ok, invitation}

      error ->
        error
    end
  end

  @doc """
  Fetches a pending invitation by space and token.

  ## Examples

      # If found, returns the invitation with preloaded space and invitor.
      get_pending_invitation!(space, "xxxxxxx")
      => %Invitation{space: %Space{...}, invitor: %User{...}, ...}

      # Otherwise, raises an `Ecto.NoResultsError` exception.
  """
  def get_pending_invitation!(space, token) do
    Invitation
    |> Repo.get_by!(space_id: space.id, state: "PENDING", token: token)
    |> Repo.preload([:space, :invitor])
  end

  @doc """
  Registers a user and marks the given invitation as accepted.

  ## Examples

      # If successful, returns the user and invitation.
      accept_invitation(invitation, %{email: "...", password: "..."})
      => {:ok, %{user: user, invitation: invitation}}

      # Otherwise, returns an error.
      => {:error, failed_operation, failed_value, changes_so_far}
  """
  def accept_invitation(invitation, params \\ %{}) do
    invitation
    |> Invitation.accept_operation(params)
    |> Repo.transaction()
  end
end