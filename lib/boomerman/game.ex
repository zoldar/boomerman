defmodule Boomerman.Game do
  use GenServer

  defmodule GameMap do
    defstruct definition: [], walls: MapSet.new(), crates: MapSet.new(), slots: []

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
              if field in ["%", "#"] do
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

      %{struct | definition: plain_definition}
    end
  end

  defmodule Player do
    defstruct [:slot, :position, velocity: 0, direction: {0, 1}]

    @tile_size 16

    def new({x, y} = slot) do
      %__MODULE__{slot: slot, position: {x * @tile_size, y * @tile_size}}
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

  @type slot() :: {non_neg_integer(), non_neg_integer()}

  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{
        map: @map,
        free_slots: @map.slots,
        players: %{},
        bombs: %{}
      },
      name: __MODULE__
    )
  end

  @spec register() :: {:ok, {map(), slot()}} | {:error, :no_slots}
  def register do
    case GenServer.call(__MODULE__, :register) do
      {:ok, {map, slot}} ->
        {:ok, _} = Registry.register(Boomerman.PlayerRegistry, "game", slot)
        {:ok, {map, slot}}

      {:error, error} ->
        {:error, error}
    end
  end

  def get_players do
    Boomerman.PlayerRegistry
    |> Registry.lookup("game")
    |> Enum.reduce([], fn {player_pid, slot}, players ->
      if player_pid != self() do
        [slot | players]
      else
        players
      end
    end)
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

    broadcast({:bomb_dropped, {x, y}, blast_radius}, self())
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

        {:reply, {:ok, {state.map.definition, slot}},
         %{state | free_slots: slots, players: Map.put(state.players, pid, Player.new(slot))}}

      [] ->
        {:reply, {:error, :no_slots}, state}
    end
  end

  def handle_call({:update_player, props}, {pid, _}, state) do
    if player = state.players[pid] do
      new_player = %{
        player
        | direction: props[:direction],
          velocity: props[:velocity],
          position: props[:position]
      }

      {:reply, {:ok, player.slot}, %{state | players: Map.put(state.players, pid, new_player)}}
    else
      {:reply, {:error, :no_player}, state}
    end
  end

  def handle_call({:drop_bomb, position, blast_radius}, {pid, _}, state) do
    if state.players[pid] do
      bomb = %Bomb{owner: pid, planted_at: System.monotonic_time(), blast_radius: blast_radius}

      {:reply, :ok, %{state | bombs: Map.put(state.bombs, position, bomb)}}
    else
      {:reply, {:error, :no_player}, state}
    end
  end

  @native_second System.convert_time_unit(1, :second, :native)

  @impl true
  def handle_info(:game_loop, state) do
    schedule_game_loop()

    now = System.monotonic_time()

    bombs =
      Enum.reduce(
        state.bombs,
        %{bombs: state.bombs, crates: state.map.crates},
        fn {position, bomb}, acc ->
          if abs(now - bomb.planted_at) > 3 * @native_second do
            %{acc | bombs: Map.delete(acc.bombs, position)}
          else
            acc
          end
        end
      )

    {:noreply, %{state | bombs: bombs}}
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
    Process.send_after(self(), :game_loop, 200)
  end

  defp schedule_slot_cleanup() do
    Process.send_after(self(), :slot_cleanup, 2000)
  end
end
