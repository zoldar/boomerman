defmodule Boomerman.Game do
  use GenServer

  @native_second System.convert_time_unit(1, :second, :native)
  @native_ms System.convert_time_unit(1, :millisecond, :native)
  @time_limit 120 * @native_second

  defmodule GameMap do
    defstruct [
      :width,
      :height,
      definition: [],
      walls: MapSet.new(),
      crates: MapSet.new(),
      slots: []
    ]

    def build(map_definition) do
      plain_definition = Enum.map(map_definition, &String.replace(&1, "P", "G"))

      struct =
        map_definition
        |> Enum.with_index()
        |> Enum.reduce(%__MODULE__{}, fn {row, y}, map ->
          row
          |> String.graphemes()
          |> Enum.with_index()
          |> Enum.reduce(map, fn {field, x}, map ->
            point = {x, y}

            walls =
              if field in ["%", "#", "@", "O", "[", "]", "{", "}"] do
                MapSet.put(map.walls, point)
              else
                map.walls
              end

            crates =
              if field == "C" do
                MapSet.put(map.crates, point)
              else
                map.crates
              end

            slots =
              if field == "P" do
                [point | map.slots]
              else
                map.slots
              end

            %{map | walls: walls, crates: crates, slots: slots}
          end)
        end)

      %{
        struct
        | definition: plain_definition,
          width: String.length(hd(plain_definition)),
          height: length(plain_definition)
      }
    end

    def remove_crate(map, {cx, cy}) do
      crates = MapSet.delete(map.crates, {cx, cy})

      definition =
        Enum.map(Enum.with_index(map.definition), fn {row, y} ->
          if cy == y do
            {pre, "C" <> post} = String.split_at(row, cx)
            pre <> "G" <> post
          else
            row
          end
        end)

      %{map | crates: crates, definition: definition}
    end
  end

  defmodule Player do
    defstruct [
      :pid,
      :slot,
      :position,
      :updated_at,
      state: :active,
      velocity: 0,
      direction: {0, 1}
    ]

    @tile_size 16

    def new(pid, {x, y} = slot) do
      %__MODULE__{
        pid: pid,
        slot: slot,
        position: {x * @tile_size, y * @tile_size},
        updated_at: System.monotonic_time()
      }
    end

    def bounding_box(%{pid: pid, position: {px, py}}) do
      %{
        key: pid,
        position: {px, py},
        width: @tile_size,
        height: @tile_size
      }
    end

    def hit_box(%{pid: pid, position: {px, py}}) do
      %{
        key: pid,
        position: {px + @tile_size / 3, py + @tile_size / 3},
        width: @tile_size / 3,
        height: @tile_size / 3
      }
    end
  end

  defmodule Bomb do
    defstruct [:owner, :planted_at, :blast_radius]
  end

  @map_definition [
    "[%%%%%%%%%%%%%%%%%%]",
    "@PSSCSSSSCPSSSSSSSPO",
    "@G#G#C#G#G#G#GGGGGGO",
    "@GGCGCGPGGGGGCGGGGGO",
    "@G#G#C#C#G#G#G[%%]GO",
    "@GGGGGGGGCGGGG@  OGO",
    "@G#G#G#G#C#G#G@  OGO",
    "@GGGGGGGCGGGGG{##}GO",
    "@G#G#G#G#G#G#GGGGGGO",
    "@PGGCGGGPCCCCGGGGGPO",
    "{##################}"
  ]

  @map GameMap.build(@map_definition)
  @tile_size 16
  @powerups [:bomb, :blast, :speed, :surprise]

  @type slot() :: {non_neg_integer(), non_neg_integer()}

  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{
        started_at: System.monotonic_time(),
        game_state: :active,
        map: @map,
        free_slots: @map.slots,
        players: %{},
        bombs: %{},
        powerups: %{}
      },
      name: __MODULE__
    )
  end

  @spec register() :: {:ok, {map(), slot(), map()}} | {:error, :no_slots}
  def register do
    case GenServer.call(__MODULE__, :register) do
      {:ok, {map, game_time_ms, slot, players, powerups, bombs}} ->
        {:ok, _} = Registry.register(Boomerman.PlayerRegistry, "game", slot)

        {:ok, {map, game_time_ms, slot, players, powerups, bombs}}

      {:error, error} ->
        {:error, error}
    end
  end

  def update(direction, velocity, position) do
    {:ok, slot} =
      GenServer.call(
        __MODULE__,
        {:update_player, direction: direction, velocity: velocity, position: position}
      )

    broadcast(
      {:player_updated,
       %{slot: slot, direction: direction, velocity: velocity, position: position}},
      self()
    )
  end

  def drop_bomb({x, y}, blast_radius) do
    :ok = GenServer.call(__MODULE__, {:drop_bomb, {x, y}, blast_radius})
  end

  def collect_powerup({x, y}) do
    :ok = GenServer.call(__MODULE__, {:collect_powerup, {x, y}})
  end

  @impl true
  def init(state) do
    schedule_game_loop()
    schedule_slot_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call(:register, {pid, _}, state) do
    case state.free_slots do
      [slot | slots] ->
        broadcast({:player_joined, slot}, pid)

        game_time_ms = (System.monotonic_time() - state.started_at) / @native_ms

        now = System.monotonic_time()

        bombs =
          Enum.map(
            state.bombs,
            fn {{bx, by},
                %{owner: player_pid, planted_at: planted_at, blast_radius: blast_radius}} ->
              planted_ago_ms = Float.round((now - planted_at) / @native_ms)
              %{slot: {owner_x, owner_y}} = state.players[player_pid]

              %{
                position: %{x: bx, y: by},
                owner: %{x: owner_x, y: owner_y},
                planted_ago_ms: planted_ago_ms,
                blast_radius: blast_radius
              }
            end
          )

        active_players =
          state.players
          |> Map.values()
          |> Enum.filter(&(&1.state == :active))

        {:reply,
         {:ok, {state.map.definition, game_time_ms, slot, active_players, state.powerups, bombs}},
         %{state | free_slots: slots, players: Map.put(state.players, pid, Player.new(pid, slot))}}

      [] ->
        {:reply, {:error, :no_slots}, state}
    end
  end

  def handle_call({:update_player, props}, {pid, _}, state) do
    if player = state.players[pid] do
      if player.state == :active do
        new_player = %{
          player
          | direction: props[:direction],
            velocity: props[:velocity],
            position: props[:position],
            updated_at: System.monotonic_time()
        }

        {:reply, {:ok, player.slot}, %{state | players: Map.put(state.players, pid, new_player)}}
      else
        state
      end
    else
      {:reply, {:error, :no_player}, state}
    end
  end

  def handle_call({:drop_bomb, {x, y}, blast_radius}, {pid, _}, state) do
    if player = state.players[pid] do
      if player.state == :active do
        state =
          if not Map.has_key?(state.bombs, {x, y}) do
            bomb = %Bomb{
              owner: pid,
              planted_at: System.monotonic_time(),
              blast_radius: blast_radius
            }

            broadcast({:bomb_dropped, {x, y}, blast_radius, player.slot}, pid)
            %{state | bombs: Map.put(state.bombs, {x, y}, bomb)}
          else
            state
          end

        {:reply, :ok, state}
      else
        {:reply, :ok, state}
      end
    else
      {:reply, {:error, :no_player}, state}
    end
  end

  def handle_call({:collect_powerup, position}, {pid, _}, state) do
    if player = state.players[pid] do
      if player.state == :active do
        if powerup = state.powerups[position] do
          final_powerup =
            if powerup == :surprise do
              Enum.random([:clear, :bomb, :blast, :speed])
            else
              powerup
            end

          send(pid, {:powerup_collected, final_powerup, position})
          broadcast({:powerup_grabbed, position}, pid)

          {:reply, :ok, %{state | powerups: Map.delete(state.powerups, position)}}
        else
          {:reply, :ok, state}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:reply, {:error, :no_player}, state}
    end
  end

  @impl true
  def handle_info(:game_loop, state) do
    if state.game_state == :active do
      schedule_game_loop()

      now = System.monotonic_time()

      state =
        Enum.reduce(
          state.bombs,
          state,
          fn {position, bomb}, state ->
            if abs(now - bomb.planted_at) > 3 * @native_second do
              broadcast({:bomb_ignited, position})
              blast_bomb(state, position, bomb.blast_radius)
            else
              state
            end
          end
        )

      {active_players, inactive_players} =
        Enum.split_with(state.players, fn {_, player} -> player.state == :active end)

      player_boxes =
        active_players
        |> Enum.map(fn {_, player} -> Player.bounding_box(player) end)

      bomb_boxes = Enum.map(state.bombs, fn {position, _} -> small_box(position) end)
      wall_boxes = Enum.map(state.map.walls, &full_box/1)
      crate_boxes = Enum.map(state.map.crates, &full_box/1)
      static_boxes = List.flatten([bomb_boxes, wall_boxes, crate_boxes])

      state =
        Enum.reduce(active_players, state, fn {pid, player}, state ->
          {px, py} = player.position
          {dx, dy} = player.direction
          seconds_passed = (now - player.updated_at) / @native_second
          delta = player.velocity * seconds_passed

          new_position = {px + dx * delta, py + dy * delta}
          new_player = %{player | position: new_position, updated_at: now}

          player_boxes = Enum.reject(player_boxes, &(&1.key == pid))

          case collisions(Player.bounding_box(new_player), player_boxes ++ static_boxes) do
            [_ | _] ->
              new_player = %{new_player | position: player.position}
              %{state | players: Map.put(state.players, pid, new_player)}

            [] ->
              %{state | players: Map.put(state.players, pid, new_player)}
          end
        end)

      state =
        case {active_players, inactive_players} do
          {[{winner_pid, _}], [_ | _]} ->
            send(winner_pid, :game_won)
            broadcast(:game_will_restart, winner_pid)
            schedule_restart()
            %{state | game_state: :inactive}

          {[], [_ | _]} ->
            broadcast(:game_will_restart)
            schedule_restart()
            %{state | game_state: :inactive}

          _ ->
            state
        end

      state =
        if state.game_state == :active and now - state.started_at > @time_limit do
          broadcast(:game_will_restart)
          schedule_restart()
          %{state | game_state: :inactive}
        else
          state
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:restart, state) do
    players =
      Enum.reduce(state.players, %{}, fn {pid, player}, players ->
        {slot_x, slot_y} = player.slot
        position = {slot_x * @tile_size, slot_y * @tile_size}

        Map.put(players, pid, %{
          player
          | position: position,
            state: :active,
            updated_at: System.monotonic_time()
        })
      end)

    Enum.each(players, fn {pid, player} ->
      {slot_x, slot_y} = player.slot

      other_players =
        players
        |> Enum.map(fn {_, player} -> player end)
        |> Enum.reject(&(&1.pid == pid))

      send(pid, {:start_game, @map.definition, {slot_x, slot_y}, other_players})
    end)

    schedule_game_loop()

    {:noreply,
     %{
       state
       | started_at: System.monotonic_time(),
         game_state: :active,
         map: @map,
         players: players,
         bombs: %{},
         powerups: %{}
     }}
  end

  def handle_info(:slot_cleanup, state) do
    schedule_slot_cleanup()

    player_pids =
      Boomerman.PlayerRegistry
      |> Registry.lookup("game")
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    %{slots: slots, players: players} =
      Enum.reduce(
        state.players,
        %{slots: state.free_slots, players: state.players},
        fn {pid, player}, acc ->
          if not MapSet.member?(player_pids, pid) do
            broadcast({:player_left, player.slot})
            %{acc | slots: [player.slot | acc.slots], players: Map.delete(acc.players, pid)}
          else
            acc
          end
        end
      )

    {:noreply, %{state | free_slots: slots, players: players}}
  end

  defp blast_bomb(state, {x, y} = position, blast_radius, blasted_bombs \\ MapSet.new()) do
    directions = [{0, 1}, {0, -1}, {-1, 0}, {1, 0}]

    player_hitboxes =
      state.players
      |> Enum.filter(fn {_, player} -> player.state == :active end)
      |> Enum.map(fn {_, player} -> Player.hit_box(player) end)

    state = blast_players(state, {x, y}, player_hitboxes)

    state =
      Enum.reduce(directions, state, fn {dx, dy}, state ->
        Enum.reduce_while(1..blast_radius, state, fn current_radius, state ->
          {cx, cy} = {x + current_radius * dx, y + current_radius * dy}

          cond do
            bomb = not MapSet.member?(blasted_bombs, {cx, cy}) && state.bombs[{cx, cy}] ->
              broadcast({:bomb_ignited, {cx, cy}})

              {:halt,
               blast_bomb(state, {cx, cy}, bomb.blast_radius, MapSet.put(blasted_bombs, position))}

            MapSet.member?(state.map.crates, {cx, cy}) ->
              broadcast({:crate_blasted, {cx, cy}})
              state = maybe_spawn_powerup(state, {cx, cy})
              {:halt, %{state | map: GameMap.remove_crate(state.map, {cx, cy})}}

            MapSet.member?(state.map.walls, {cx, cy}) ->
              {:halt, state}

            true ->
              {:cont, blast_players(state, {cx, cy}, player_hitboxes)}
          end
        end)
      end)

    %{state | bombs: Map.delete(state.bombs, position)}
  end

  defp maybe_spawn_powerup(state, {x, y}) do
    if Enum.random(1..2) == 2 and map_size(state.powerups) < 5 do
      powerup = Enum.random(@powerups)
      broadcast({:powerup_spawned, powerup, {x, y}})
      %{state | powerups: Map.put(state.powerups, {x, y}, powerup)}
    else
      state
    end
  end

  defp blast_players(state, {cx, cy}, player_hitboxes) do
    hit_pids =
      collisions(full_box({cx, cy}), player_hitboxes)

    players =
      Enum.reduce(hit_pids, state.players, fn pid, players ->
        if hit_player = players[pid] do
          broadcast({:player_blasted, hit_player.slot}, pid)
          send(pid, :game_lost)
          Map.put(players, pid, %{hit_player | state: :eliminated})
        else
          players
        end
      end)

    %{state | players: players}
  end

  defp collisions(box, other_boxes) do
    other_boxes
    |> Enum.filter(&collides?(&1, box))
    |> Enum.map(& &1.key)
  end

  defp collides?(
         %{position: {x1, y1}, width: w1, height: h1},
         %{position: {x2, y2}, width: w2, height: h2}
       ) do
    x1 < x2 + w2 and x1 + w1 > x2 and y1 < y2 + h2 and y1 + h1 > y2
  end

  defp full_box({px, py}) do
    %{
      position: {px * @tile_size, py * @tile_size},
      width: @tile_size,
      height: @tile_size,
      key: {:f, px, py}
    }
  end

  defp small_box({px, py}) do
    %{
      key: {:s, px, py},
      position: {px * @tile_size + @tile_size / 3, py * @tile_size + @tile_size / 3},
      width: @tile_size / 3,
      height: @tile_size / 3
    }
  end

  defp broadcast(message, except \\ nil) do
    Boomerman.PlayerRegistry
    |> Registry.lookup("game")
    |> Enum.each(fn {player_pid, _} ->
      if player_pid != except do
        send(player_pid, message)
      end
    end)
  end

  defp schedule_game_loop() do
    Process.send_after(self(), :game_loop, 100)
  end

  defp schedule_slot_cleanup() do
    Process.send_after(self(), :slot_cleanup, 2000)
  end

  defp schedule_restart() do
    Process.send_after(self(), :restart, 3000)
  end
end
