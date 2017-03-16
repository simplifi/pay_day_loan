defmodule GenericCacheTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory

  #our cache for testing
  defmodule PDLTestGenericCache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      batch_size: 10,
      load_wait_msec: 50,
      callback_module: GenericCacheTest.PDLTestGenericImplementation
    )
  end

  defmodule CacheBackend do
    def start_link() do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def get(key) do
      case Agent.get(__MODULE__, fn(m) -> Map.get(m, key) end) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end

    def put(key, value) do
      Agent.update(__MODULE__, fn(m) -> Map.put(m, key, "V#{value}") end)
    end

    def delete(key) do
      Agent.update(__MODULE__, fn(m) -> Map.delete(m, key) end)
    end
  end

  # loader behaviour implementation
  defmodule PDLTestGenericImplementation do
    use PayDayLoan.Support.TestImplementation

    def on_new(key, value) do
      CacheBackend.put(key, value)
      {:ok, &CacheBackend.get/1}
    end

    def on_remove(key, _value) do
      CacheBackend.delete(key)
    end

    def on_replace(_old_value, key, _value) do
      CacheBackend.put(key, "replaced")
      {:ok, &CacheBackend.get/1}
    end

    def on_update(_old_value, key, value) do
      CacheBackend.put(key, value)
      {:ok, &CacheBackend.get/1}
    end
  end

  def pdl do
    PDLTestGenericCache.pdl()
  end
  
  use PayDayLoan.Support.CommonTests

  setup do
    CacheBackend.start_link()
    :ok
  end

  test "basic integration test" do
    assert 0 == PDL.EtsBackend.size(pdl())

    assert {:error, :not_found} == PDL.peek(pdl(), 1)

    assert :requested == PDL.query_load_state(pdl(), 1)

    GenServer.cast(pdl().load_worker, :ping)

    {:ok, "V1"} = PDLTestGenericCache.get(1)

    assert :loaded == PDL.query_load_state(pdl(), 1)

    assert {:ok, "V1"} == PDL.peek(pdl(), 1)

    assert PDL.KeyCache.in_cache?(pdl().key_cache, 1)
  end

  test "loading happens in bulk" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = PDLTestGenericCache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == PDLTestGenericCache.size

    assert length(LoadHistory.bulk_loads) > 0
    assert n == length(LoadHistory.news)
    assert 0 == length(LoadHistory.refreshes)

    (1..n)
    |> Enum.each(fn(ix) ->
      assert PDL.KeyCache.in_cache?(pdl().key_cache, ix)
    end)
  end

  test "refreshing a cache element" do
    replaced_key = PDLTestGenericImplementation.key_that_shall_be_replaced

    assert {:ok, "V1"} == PDLTestGenericCache.get(1)
    assert {:ok, "V#{replaced_key}"} == PDLTestGenericCache.get(replaced_key)

    news = LoadHistory.news
    assert 2 == length(news)
    assert Enum.member?(news, {:new, [1, 1]})
    assert Enum.member?(news, {:new, [replaced_key, replaced_key]})

    assert {:ok, "V1"} == CacheBackend.get(1)
    assert {:ok, "V#{replaced_key}"} == CacheBackend.get(replaced_key)

    PDLTestGenericCache.request_load([1, replaced_key])

    wait_for(
      fn ->
        PDL.LoadState.any_requested?(pdl().load_state_manager)
      end
    )

    assert {:ok, "V1"} == PDLTestGenericCache.get(1)
    assert {:ok, "V1"} == CacheBackend.get(1)

    assert {:ok, "Vreplaced"} == PDLTestGenericCache.get(replaced_key)
    assert {:ok, "Vreplaced"} == CacheBackend.get(replaced_key)

    refreshes = LoadHistory.refreshes
    assert 2 == length(refreshes)
    assert Enum.member?(refreshes, {:refresh, ["V1", 1, 1]})
    assert Enum.member?(
      refreshes,
      {:refresh, ["V#{replaced_key}", replaced_key, replaced_key]}
    )
  end

  test "requesting a key that is in key cache but fails to load" do
    key = PDLTestGenericImplementation.key_that_shall_not_be_loaded

    assert {:error, :failed} == PDLTestGenericCache.get_pid(key)
    assert [{:loaded, [key]}] == LoadHistory.loads
    assert nil == PDL.LoadState.peek(pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(pdl().key_cache, key)
  end

  test "requesting a key that does not exist" do
    key = PDLTestGenericImplementation.key_that_does_not_exist

    assert {:error, :not_found} == PDLTestGenericCache.get_pid(key)
    assert [] == LoadHistory.loads
    refute PDL.KeyCache.in_cache?(pdl().key_cache, key)
  end

  test "large batches don't require an extra ping" do
    batch_size = pdl().batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    PDLTestGenericCache.request_load(keys)

    wait_for(fn -> length(keys) == PDLTestGenericCache.size end)

    assert length(keys) == PDLTestGenericCache.size
  end

  test "load failures are ignored (should be handled in callback)" do
    key = PDLTestGenericImplementation.key_that_will_not_new
    assert {:error, :failed} == PDLTestGenericCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "refresh failures are ignored (should be handled in callback)" do
    key = PDLTestGenericImplementation.key_that_will_not_refresh

    # it should load
    {:ok, _value} = PDLTestGenericCache.get(key)

    PDLTestGenericCache.request_load(key)

    # the refresh fixture will delete the existing value
    wait_for(fn -> CacheBackend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == PDLTestGenericCache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "working with key/value lists" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _value} = PDLTestGenericCache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == PDLTestGenericCache.size

    expect_keys = Enum.to_list(1..n)
    expect_values = Enum.map(expect_keys, fn(k) -> "V#{k}" end)

    assert MapSet.new(expect_keys) == MapSet.new(PDLTestGenericCache.keys)
    assert MapSet.new(expect_values) == MapSet.new(PDLTestGenericCache.values)

    expect_map = Enum.reduce(expect_keys, %{},
      fn(k, acc) ->
        {:ok, value} = CacheBackend.get(k)
        Map.put(acc, k, value)
      end)
    
    got_map = PDLTestGenericCache.reduce(%{},
      fn({k, value}, acc) -> Map.put(acc, k, value) end)

    assert expect_map == got_map
  end

  test "when a value is removed from the backend, its key is unloaded" do
    key = PDLTestGenericImplementation.key_that_is_removed_from_backend
    {:ok, v1} = PDLTestGenericCache.get(key)

    assert {:ok, v1} == CacheBackend.get(key)

    # delete on the backend
    CacheBackend.delete(key)

    assert {:error, :not_found} == PDLTestGenericCache.get(key)
    assert nil == PDL.LoadState.peek(pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(pdl().key_cache, key)
  end

  test "when the monitor is killed, it restarts" do
    {:ok, "V1"} = PDLTestGenericCache.get(1)

    previous_pid = Process.whereis(pdl().cache_monitor)

    :ok = GenServer.stop(pdl().cache_monitor)

    # make sure that it restarts via the supervisor
    wait_for(fn ->
      pid = Process.whereis(pdl().cache_monitor)
      is_pid(pid) && Process.alive?(pid)
    end)

    refute previous_pid == Process.whereis(pdl().cache_monitor)

    # cache state is unchanged
    assert {:ok, "V1"} == PDLTestGenericCache.get(1)
  end

  test "manually adding an element to the cache" do
    CacheBackend.put(1, 42)
    PDLTestGenericCache.cache(1, &CacheBackend.get/1)

    assert [1] == PDLTestGenericCache.keys
    assert ["V42"] == PDLTestGenericCache.values

    assert {:ok, "V42"} == PDLTestGenericCache.get(1)

    # can't be manually overwritten
    assert {:error, "V42"} == PDLTestGenericCache.cache(1, 0)
  end

  test "manually removing an element from the cache" do
    {:ok, v} = PDLTestGenericCache.get(1)

    assert {:ok, v} == PDLTestGenericCache.get(1)

    :ok = PayDayLoan.uncache_key(pdl(), 1)

    assert [] == PDLTestGenericCache.keys
    assert [] == PDLTestGenericCache.values

    # value is still in the backend
    assert {:ok, "V1"} == CacheBackend.get(1)
  end

  test "when new returns :ignore" do
    key = PDLTestGenericImplementation.key_that_returns_ignore_on_new
    assert {:error, :failed} == PDLTestGenericCache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "refresh :ignore failures are ignored (should be handled in callback)" do
    key = PDLTestGenericImplementation.key_that_returns_ignore_on_refresh

    # it should load
    {:ok, _v} = PDLTestGenericCache.get(key)

    PDLTestGenericCache.request_load(key)

    # the refresh fixture will remove the existing value
    wait_for(fn -> CacheBackend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == PDLTestGenericCache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end
end
