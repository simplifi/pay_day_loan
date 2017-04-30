defmodule PayDayLoan.Backends.BehaviourTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory

  #our cache for testing
  defmodule Cache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      backend: PayDayLoan.Backends.BehaviourTest.Backend,
      cache_monitor: false,
      batch_size: 10,
      load_wait_msec: 50,
      callback_module: PayDayLoan.Backends.BehaviourTest.Implementation
    )
  end

  defmodule Backend do
    @behaviour PayDayLoan.Backend

    def start_link(), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def setup(_), do: :ok

    def reduce(_pdl, acc0, reducer) do
      Agent.get(__MODULE__, fn(m) -> Enum.reduce(m, acc0, reducer) end)
    end

    def size(_pdl), do: Agent.get(__MODULE__, &Map.size/1) 

    def keys(_pdl), do: Agent.get(__MODULE__, &Map.keys/1)

    def values(_pdl), do: Agent.get(__MODULE__, &Map.values/1)

    # for convenience, not one of the required callbacks
    def get(key), do: get(Cache.pdl(), key)

    def get(_pdl, key) do
      case Agent.get(__MODULE__, fn(m) -> Map.get(m, key) end) do
        nil -> {:error, :not_found}
        v -> {:ok, v}
      end
    end

    def put(_pdl, key, val) do
      Agent.update(__MODULE__, fn(m) -> Map.put(m, key, "V#{val}") end)
    end

    def delete(_pdl, key) do
      Agent.update(__MODULE__, fn(m) -> Map.delete(m, key) end)
    end
  end

  # loader behaviour implementation
  defmodule Implementation do
    use PayDayLoan.Support.TestImplementation

    def on_new(_key, value) do
      {:ok, value}
    end

    def on_remove(key, _value) do
      Backend.delete(Cache.pdl(), key)
    end

    def on_replace(_old_value, _key, _value) do
      {:ok, "replaced"}
    end

    def on_update(_old_value, _key, value) do
      {:ok, value}
    end
  end

  use PayDayLoan.Support.CommonTests, cache: Cache

  setup do
    Backend.start_link()
    :ok
  end

  test "basic integration test" do
    key = 1

    assert 0 == Cache.pdl().backend.size(Cache.pdl())

    assert {:error, :not_found} == PDL.peek(Cache.pdl(), key)
    assert :requested == PDL.query_load_state(Cache.pdl(), key)

    GenServer.cast(Cache.pdl().load_worker, :ping)

    get_result = Cache.get(key)
    assert :loaded == PDL.query_load_state(Cache.pdl(), key)
    assert get_result == PDL.peek(Cache.pdl(), key)
    assert get_result == Backend.get(Cache.pdl(), key)

    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "loading happens in bulk" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = Cache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == Cache.size

    assert length(LoadHistory.bulk_loads) > 0
    assert n == length(LoadHistory.news)
    assert 0 == length(LoadHistory.refreshes)

    (1..n)
    |> Enum.each(fn(ix) ->
      assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, ix)
    end)
  end

  test "refreshing a cache element" do
    replaced_key = Implementation.key_that_shall_be_replaced

    assert {:ok, "V1"} == Cache.get(1)
    assert {:ok, "V#{replaced_key}"} == Cache.get(replaced_key)

    news = LoadHistory.news
    assert 2 == length(news)
    assert Enum.member?(news, {:new, [1, 1]})
    assert Enum.member?(news, {:new, [replaced_key, replaced_key]})

    assert {:ok, "V1"} == Backend.get(1)
    assert {:ok, "V#{replaced_key}"} == Backend.get(replaced_key)

    Cache.request_load([1, replaced_key])

    wait_for(
      fn ->
        !PDL.LoadState.any_requested?(Cache.pdl().load_state_manager)
      end
    )

    assert {:ok, "V1"} == Cache.get(1)
    assert {:ok, "V1"} == Backend.get(1)

    assert {:ok, "Vreplaced"} == Cache.get(replaced_key)
    assert {:ok, "Vreplaced"} == Backend.get(replaced_key)

    refreshes = LoadHistory.refreshes
    assert 2 == length(refreshes)
    assert Enum.member?(refreshes, {:refresh, ["V1", 1, 1]})
    assert Enum.member?(
      refreshes,
      {:refresh, ["V#{replaced_key}", replaced_key, replaced_key]}
    )
  end

  test "requesting a key that is in key cache but fails to load" do
    key = Implementation.key_that_shall_not_be_loaded

    assert {:error, :failed} == Cache.get(key)
    assert [{:loaded, [key]}] == LoadHistory.loads
    assert nil == PDL.LoadState.peek(Cache.pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "requesting a key that does not exist" do
    key = Implementation.key_that_does_not_exist

    assert {:error, :not_found} == Cache.get(key)
    assert [] == LoadHistory.loads
    refute PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "large batches don't require an extra ping" do
    batch_size = Cache.pdl().batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    Cache.request_load(keys)

    wait_for(fn -> length(keys) == Cache.size end)

    assert length(keys) == Cache.size
  end

  test "load failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_new
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "refresh failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_refresh

    # it should load
    {:ok, _value} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will delete the existing value
    wait_for(fn -> Backend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "working with key/value lists" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _value} = Cache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == Cache.size

    expect_keys = Enum.to_list(1..n)
    expect_values = Enum.map(expect_keys, fn(k) -> "V#{k}" end)

    assert MapSet.new(expect_keys) == MapSet.new(Cache.keys)
    assert MapSet.new(expect_values) == MapSet.new(Cache.values)

    expect_map = Enum.reduce(expect_keys, %{},
      fn(k, acc) ->
        {:ok, value} = Backend.get(k)
        Map.put(acc, k, value)
      end)
    
    got_map = Cache.reduce(%{},
      fn({k, value}, acc) -> Map.put(acc, k, value) end)

    assert expect_map == got_map
  end

  test "when a value is removed from the backend, its key is unloaded" do
    key = Implementation.key_that_is_removed_from_backend
    {:ok, v1} = Cache.get(key)

    assert {:ok, v1} == Backend.get(key)

    # delete on the backend
    Backend.delete(Cache.pdl(), key)

    assert {:error, :failed} == Cache.get(key)
    assert nil == PDL.LoadState.peek(Cache.pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "manually adding an element to the cache" do
    Backend.put(Cache.pdl(), 1, 42)

    assert [1] == Cache.keys
    assert ["V42"] == Cache.values
    assert {:ok, "V42"} == Backend.get(1)

    # this frontend isn't configured to check the backend before inserting
    #   we could easily do that in the loader if we wanted to
    assert {:ok, "V1"} == Cache.get(1)
  end

  test "manually removing an element from the cache" do
    {:ok, v} = Cache.get(1)

    assert {:ok, v} == Cache.get(1)

    :ok = PayDayLoan.uncache_key(Cache.pdl(), 1)

    assert [] == Cache.keys
    assert [] == Cache.values

    # we make the callthrough to the backend, so it is also removed from there
    assert {:error, :not_found} == Backend.get(1)
  end

  test "when new returns :ignore" do
    key = Implementation.key_that_returns_ignore_on_new
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "refresh :ignore failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_returns_ignore_on_refresh

    # it should load
    {:ok, _v} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will remove the existing value
    wait_for(fn -> Backend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "reloading does not block" do
    key = Implementation.key_that_reloads_slowly

    {:ok, v} = Cache.get(key)

    Cache.request_load(key)
    # if we call this immediately, we should get the old value
    assert {:ok, v} == Cache.get(key)

    Patiently.wait_for!(fn ->
      {:ok, v_new} = Cache.get(key)
      v_new != v
    end)
    assert :loaded == Cache.peek_load_state(key)
    assert 1 == Cache.size
  end
end
