defmodule Boomerman.Game do
  use GenServer

  defmodule Map do
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

  @map_definition [
    "%##################%",
    "%PGGCGGGGCPGGGGGGGP%",
    "%G#G#C#G#G#G#GGGGGG%",
    "%GGCGCGPGGGGGCGGGGG%",
    "%G#G#C#C#G#G#G%##%G%",
    "%GGGGGGGGCGGGG%  %G%",
    "%G#G#G#G#C#G#G%  %G%",
    "%GGGGGGGCGGGGG%##%G%",
    "%G#G#G#G#G#G#GGGGGG%",
    "%PGGCGGGPCCCCGGGGGP%",
    "%##################%"
  ]

  @map Map.build(@map_definition)

  @type slot() :: {non_neg_integer(), non_neg_integer()}

  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{
        map: @map,
        free_slots: @map.slots,
        busy_slots: []
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
    slot = get_slot(self())

    broadcast(
      {:player_updated,
       %{slot: slot, direction: direction, velocity: velocity, position: position}},
      self()
    )
  end

  def drop_bomb({x, y}) do
    broadcast({:bomb_dropped, {x, y}}, self())
  end

  @impl true
  def init(state) do
    schedule_game_loop()
    schedule_slot_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call(:register, from, state) do
    case state.free_slots do
      [slot | slots] ->
        broadcast({:player_joined, slot}, from)

        {:reply, {:ok, {state.map.definition, slot}},
         %{state | free_slots: slots, busy_slots: [slot | state.busy_slots]}}

      [] ->
        {:reply, {:error, :no_slots}, state}
    end
  end

  @impl true
  def handle_info(:game_loop, state) do
    schedule_game_loop()

    {:noreply, state}
  end

  def handle_info(:slot_cleanup, state) do
    schedule_slot_cleanup()

    busy_slots =
      Boomerman.PlayerRegistry
      |> Registry.lookup("game")
      |> Enum.map(&elem(&1, 1))

    freed_slots = state.busy_slots -- busy_slots

    Enum.each(freed_slots, &broadcast({:player_left, &1}))

    {:noreply, %{state | free_slots: state.free_slots ++ freed_slots, busy_slots: busy_slots}}
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

  defp get_slot(pid) do
    Boomerman.PlayerRegistry
    |> Registry.lookup("game")
    |> Enum.find_value(fn {player_pid, slot} ->
      if player_pid == pid do
        slot
      end
    end)
  end
end
