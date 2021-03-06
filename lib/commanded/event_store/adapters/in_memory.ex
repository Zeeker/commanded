defmodule Commanded.EventStore.Adapters.InMemory do
  @moduledoc """
  An in-memory event store adapter useful for testing as no persistence provided.
  """

  @behaviour Commanded.EventStore

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [
      persisted_events: [],
      streams: %{},
      subscriptions: %{},
      snapshots: %{},
      next_event_number: 1
    ]
  end

  defmodule Subscription do
    @moduledoc false
    defstruct [
      name: nil,
      subscriber: nil,
      start_from: nil,
      last_seen_event_number: 0,
    ]
  end

  alias Commanded.EventStore.Adapters.InMemory.{
    State,
    Subscription,
  }
  alias Commanded.EventStore.{
    EventData,
    RecordedEvent,
    SnapshotData,
  }

  def start_link do
    GenServer.start_link(__MODULE__, %State{}, name: __MODULE__)
  end

  def init(%State{} = state) do
    {:ok, state}
  end

  def append_to_stream(stream_uuid, expected_version, events) do
    GenServer.call(__MODULE__, {:append_to_stream, stream_uuid, expected_version, events})
  end

  def stream_forward(stream_uuid, start_version \\ 0, read_batch_size \\ 1_000)
  def stream_forward(stream_uuid, start_version, _read_batch_size) do
    GenServer.call(__MODULE__, {:stream_forward, stream_uuid, start_version})
  end

  def subscribe_to_all_streams(subscription_name, subscriber, start_from) do
    subscription = %Subscription{name: subscription_name, subscriber: subscriber, start_from: start_from}

    GenServer.call(__MODULE__, {:subscribe_to_all_streams, subscription})
  end

  def ack_event(pid, event) do
    GenServer.cast(__MODULE__, {:ack_event, event, pid})
  end

  def unsubscribe_from_all_streams(subscription_name) do
    GenServer.call(__MODULE__, {:unsubscribe_from_all_streams, subscription_name})
  end

  def read_snapshot(source_uuid) do
    GenServer.call(__MODULE__, {:read_snapshot, source_uuid})
  end

  def record_snapshot(snapshot) do
    GenServer.call(__MODULE__, {:record_snapshot, snapshot})
  end

  def delete_snapshot(source_uuid) do
    GenServer.call(__MODULE__, {:delete_snapshot, source_uuid})
  end

  def handle_call({:append_to_stream, stream_uuid, expected_version, events}, _from, %State{streams: streams} = state) do
    case Map.get(streams, stream_uuid) do
      nil ->
        case expected_version do
          0 ->
            {reply, state} = persist_events(stream_uuid, [], events, state)

            {:reply, reply, state}
          _ -> {:reply, {:error, :wrong_expected_version}, state}
        end

      existing_events when length(existing_events) != expected_version ->
        {:reply, {:error, :wrong_expected_version}, state}

      existing_events ->
        {reply, state} = persist_events(stream_uuid, existing_events, events, state)

        {:reply, reply, state}
    end
  end

  def handle_call({:stream_forward, stream_uuid, start_version}, _from, %State{streams: streams} = state) do
    reply = case Map.get(streams, stream_uuid) do
      nil -> {:error, :stream_not_found}
      events -> Stream.drop(events, max(0, start_version - 1))
    end

    {:reply, reply, state}
  end

  def handle_call({:subscribe_to_all_streams, %Subscription{name: subscription_name, subscriber: subscriber} = subscription}, _from, %State{subscriptions: subscriptions} = state) do
    {reply, state} = case Map.get(subscriptions, subscription_name) do
      nil ->
        state = subscribe(subscription, state)

        {{:ok, subscriber}, state}

      %Subscription{subscriber: nil} = subscription ->
        state = subscribe(%Subscription{subscription | subscriber: subscriber}, state)

        {{:ok, subscriber}, state}

      _subscription -> {{:error, :subscription_already_exists}, state}
    end

    {:reply, reply, state}
  end

  def handle_call({:unsubscribe_from_all_streams, subscription_name}, _from, %State{subscriptions: subscriptions} = state) do
    state = %State{state |
      subscriptions: Map.delete(subscriptions, subscription_name),
    }

    {:reply, :ok, state}
  end

  def handle_call({:read_snapshot, source_uuid}, _from, %State{snapshots: snapshots} = state) do
    reply = case Map.get(snapshots, source_uuid, nil) do
      nil -> {:error, :snapshot_not_found}
      snapshot -> {:ok, snapshot}
    end

    {:reply, reply, state}
  end

  def handle_call({:record_snapshot, %SnapshotData{source_uuid: source_uuid} = snapshot}, _from, %State{snapshots: snapshots} = state) do
    state = %State{state |
      snapshots: Map.put(snapshots, source_uuid, snapshot),
    }

    {:reply, :ok, state}
  end

  def handle_call({:delete_snapshot, source_uuid}, _from, %State{snapshots: snapshots} = state) do
    state = %State{state |
      snapshots: Map.delete(snapshots, source_uuid)
    }

    {:reply, :ok, state}
  end

  def handle_cast({:ack_event, event, subscriber}, %State{subscriptions: subscriptions} = state) do
    state = %State{state |
      subscriptions: ack_subscription_by_pid(subscriptions, event, subscriber),
    }

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{subscriptions: subscriptions} = state) do
    state = %State{state |
      subscriptions: remove_subscriber_by_pid(subscriptions, pid),
    }

    {:noreply, state}
  end

  defp persist_events(stream_uuid, existing_events, new_events, %State{persisted_events: persisted_events, streams: streams, next_event_number: next_event_number} = state) do
    initial_stream_version = length(existing_events) + 1
    now = DateTime.utc_now() |> DateTime.to_naive()

    new_events =
      new_events
      |> Enum.with_index(0)
      |> Enum.map(fn {recorded_event, index} ->
        map_to_recorded_event(next_event_number + index, stream_uuid, initial_stream_version + index, now, recorded_event)
      end)

    stream_events = Enum.concat(existing_events, new_events)
    next_event_number = List.last(new_events).event_number + 1

    state = %State{state |
      streams: Map.put(streams, stream_uuid, stream_events),
      persisted_events: [new_events | persisted_events],
      next_event_number: next_event_number,
    }

    publish(new_events, state)

    {{:ok, length(stream_events)}, state}
  end

  defp map_to_recorded_event(event_number, stream_uuid, stream_version, now, %EventData{correlation_id: correlation_id, event_type: event_type, data: data, metadata: metadata}) do
    %RecordedEvent{
      event_number: event_number,
      stream_id: stream_uuid,
      stream_version: stream_version,
      correlation_id: correlation_id,
      event_type: event_type,
      data: data,
      metadata: metadata,
      created_at: now,
    }
  end

  defp subscribe(%Subscription{name: subscription_name, subscriber: subscriber} = subscription, %State{subscriptions: subscriptions, persisted_events: persisted_events} = state) do
    Process.monitor(subscriber)

    catch_up(subscription, persisted_events)

    %State{state |
      subscriptions: Map.put(subscriptions, subscription_name, subscription),
    }
  end

  defp remove_subscriber_by_pid(subscriptions, pid) do
    Enum.reduce(subscriptions, subscriptions, fn
      ({name, %Subscription{subscriber: subscriber} = subscription}, acc) when subscriber == pid -> Map.put(acc, name, %Subscription{subscription | subscriber: nil})
      (_, acc) -> acc
    end)
  end

  defp ack_subscription_by_pid(subscriptions, %RecordedEvent{event_number: event_number}, pid) do
    Enum.reduce(subscriptions, subscriptions, fn
      ({name, %Subscription{subscriber: subscriber} = subscription}, acc) when subscriber == pid -> Map.put(acc, name, %Subscription{subscription | last_seen_event_number: event_number})
      (_, acc) -> acc
    end)
  end

  defp catch_up(%Subscription{start_from: :current}, _persisted_events), do: :ok

  defp catch_up(%Subscription{subscriber: subscriber, start_from: :origin, last_seen_event_number: last_seen_event_number}, persisted_events) do
    unseen_events =
      persisted_events
      |> Enum.reverse()
      |> Enum.drop(last_seen_event_number)

    for events <- unseen_events, do: send(subscriber, {:events, events})
  end

  # publish events to subscribers
  defp publish(events, %State{subscriptions: subscriptions}) do
    for %Subscription{subscriber: subscriber} <- Map.values(subscriptions), do: send(subscriber, {:events, events})
  end
end
