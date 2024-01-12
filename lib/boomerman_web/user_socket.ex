defmodule BoomermanWeb.UserSocket do
  @behaviour Phoenix.Socket.Transport

  alias Boomerman.Game

  def child_spec(_opts) do
    # We won't spawn any process, so let's ignore the child spec
    :ignore
  end

  def connect(state) do
    # Callback to retrieve relevant data from the connection.
    # The map contains options, params, transport and endpoint keys.
    {:ok, state}
  end

  def init(state) do
    # Now we are effectively inside the process that maintains the socket.
    schedule_ping()

    {:ok, state}
  end

  def handle_in({"register", _opts}, state) do
    case Game.register() do
      {:ok, {map, game_time_ms, {x, y}, players, powerups, bombs}} ->
        players =
          Enum.map(
            players,
            fn %{slot: {sx, sy}, position: {px, py}} ->
              %{slot: %{x: sx, y: sy}, position: %{x: px, y: py}}
            end
          )

        powerups = Enum.map(powerups, fn {{x, y}, powerup} -> %{x: x, y: y, powerup: powerup} end)

        {:reply, :ok,
         {:text,
          Jason.encode!(%{
            action: :registered,
            x: x,
            y: y,
            game_time_ms: game_time_ms,
            map: map,
            players: players,
            powerups: powerups,
            bombs: bombs
          })}, state}

      {:error, reason} ->
        {:reply, :error, {:text, Jason.encode!(%{error: true, reason: reason})}, state}
    end
  end

  def handle_in({"pong", _opts}, state) do
    schedule_ping()
    {:ok, state}
  end

  def handle_in({"[\"u\"" <> _ = message, _opts}, state) do
    [_, direction_x, direction_y, velocity, x, y] = Jason.decode!(message)

    Game.update({direction_x, direction_y}, velocity, {x, y})

    {:ok, state}
  end

  def handle_in({"[\"b\"" <> _ = message, _opts}, state) do
    [_, bomb_x, bomb_y, blast_radius] = Jason.decode!(message)

    Game.drop_bomb({bomb_x, bomb_y}, blast_radius)

    {:ok, state}
  end

  def handle_in({"[\"cp\"" <> _ = message, _opts}, state) do
    [_, x, y] = Jason.decode!(message)

    Game.collect_powerup({x, y})

    {:ok, state}
  end

  def handle_info({:player_joined, {x, y}}, state) do
    {:push, {:text, Jason.encode!(%{action: :player_joined, x: x, y: y})}, state}
  end

  def handle_info({:player_left, {x, y}}, state) do
    {:push, {:text, Jason.encode!(%{action: :player_left, x: x, y: y})}, state}
  end

  def handle_info(
        {:player_updated,
         %{
           slot: {slot_x, slot_y},
           direction: {dir_x, dir_y},
           velocity: velocity,
           position: {pos_x, pos_y}
         }},
        state
      ) do
    {:push, {:text, Jason.encode!(["pu", slot_x, slot_y, dir_x, dir_y, velocity, pos_x, pos_y])},
     state}
  end

  def handle_info({:bomb_dropped, {x, y}, blast_radius, {slot_x, slot_y}}, state) do
    {:push, {:text, Jason.encode!(["b", x, y, blast_radius, slot_x, slot_y])}, state}
  end

  def handle_info({:bomb_ignited, {x, y}}, state) do
    {:push, {:text, Jason.encode!(["bi", x, y])}, state}
  end

  def handle_info({:crate_blasted, {x, y}}, state) do
    {:push, {:text, Jason.encode!(["cb", x, y])}, state}
  end

  def handle_info({:powerup_spawned, powerup, {x, y}}, state) do
    {:push, {:text, Jason.encode!(["ps", powerup, x, y])}, state}
  end

  def handle_info({:powerup_collected, powerup, {x, y}}, state) do
    {:push, {:text, Jason.encode!(["pc", powerup, x, y])}, state}
  end

  def handle_info({:powerup_grabbed, {x, y}}, state) do
    {:push, {:text, Jason.encode!(["pg", x, y])}, state}
  end

  def handle_info({:player_blasted, {slot_x, slot_y}}, state) do
    {:push, {:text, Jason.encode!(["pb", slot_x, slot_y])}, state}
  end

  def handle_info(:game_lost, state) do
    {:push, {:text, Jason.encode!(%{action: :game_lost})}, state}
  end

  def handle_info(:game_won, state) do
    {:push, {:text, Jason.encode!(%{action: :game_won})}, state}
  end

  def handle_info(:game_will_restart, state) do
    {:push, {:text, Jason.encode!(%{action: :game_will_restart})}, state}
  end

  def handle_info({:start_game, map, {x, y}, players}, state) do
    players =
      Enum.map(
        players,
        fn %{slot: {sx, sy}, position: {px, py}} ->
          %{slot: %{x: sx, y: sy}, position: %{x: px, y: py}}
        end
      )

    {:push,
     {:text, Jason.encode!(%{action: :game_started, x: x, y: y, map: map, players: players})},
     state}
  end

  def handle_info(:send_ping, state) do
    {:push, {:text, "ping"}, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp schedule_ping() do
    Process.send_after(self(), :send_ping, 10_000)
  end
end
