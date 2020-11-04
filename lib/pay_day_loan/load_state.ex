defmodule PayDayLoan.LoadState do
  @moduledoc """
  Keeps track of which keys are loaded, requested, and loading

  Acts as a state tracker and a queue for the loader.

  You shouldn't need to call any of these functions manually but
  they can be useful for debugging.
  """

  @typedoc """
  Load states that a key can have.

  * `:requested` - A load has been requested.  The load worker should
    pick this up and set the state to `:loading`.
  * `:reload` - A value is available and a reload has been requested.
  * `:loading` - The load worker is in the process of loading this key.
  * `:reload_loading` - The load worker is in the process of loading this
     key, but it is already loaded and will not block.
  * `:loaded` - The key is loaded in cache.
  * `:failed` - The key attempted a load or refresh and failed.
  """
  @type t :: :requested | :reload | :loading | :loaded | :failed | :reload_loading

  # creates the ETS table
  @doc false
  @spec create_table(atom) :: :ok
  def create_table(ets_table_id) do
    _ =
      :ets.new(
        ets_table_id,
        [:set, :public, :named_table, {:read_concurrency, true}]
      )

    :ok
  end

  @doc """
  Set the load state to `:requested` if not loaded or loading,
  return the load state
  """
  @spec query(atom, PayDayLoan.key() | [PayDayLoan.key()]) :: t | [t]
  def query(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> query(ets_table_id, key) end)
  end

  def query(ets_table_id, key) do
    case :ets.lookup(ets_table_id, key) do
      [] ->
        :requested = request(ets_table_id, key)

      [{^key, status}] ->
        status
    end
  end

  @doc """
  Return load state without modifying; return nil if key is not found
  """
  @spec peek(atom, PayDayLoan.key() | [PayDayLoan.key()]) :: t | nil | [t | nil]
  def peek(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> peek(ets_table_id, key) end)
  end

  def peek(ets_table_id, key) do
    case :ets.lookup(ets_table_id, key) do
      [] -> nil
      [{^key, status}] -> status
    end
  end

  @doc """
  Set state to `:requested`
  """
  @spec request(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :requested | [:requested]
  def request(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> request(ets_table_id, key) end)
  end

  def request(ets_table_id, key) do
    set_status(ets_table_id, key, :requested)
  end

  @doc """
  Set the state to `:reload`
  """
  @spec reload(atom, PayDayLoan.key() | [PayDayLoan.key()]) :: :reload | [:reload]
  def reload(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> reload(ets_table_id, key) end)
  end

  def reload(ets_table_id, key) do
    set_status(ets_table_id, key, :reload)
  end

  @doc """
  Set the state to `:reload` if the key is loaded, set it to `:request` if it
  is not
  """
  @spec request_or_reload(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :request | :reload | [:request | :reload]
  def request_or_reload(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> request_or_reload(ets_table_id, key) end)
  end

  def request_or_reload(ets_table_id, key) do
    if peek(ets_table_id, key) == :loaded do
      reload(ets_table_id, key)
    else
      request(ets_table_id, key)
    end
  end

  @doc """
  Set state to `:loaded`
  """
  @spec loaded(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :loaded | [:loaded]
  def loaded(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> loaded(ets_table_id, key) end)
  end

  def loaded(ets_table_id, key) do
    set_status(ets_table_id, key, :loaded)
  end

  @doc """
  Set state to `:loading`
  """
  @spec loading(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :loading | [:loading]
  def loading(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> loading(ets_table_id, key) end)
  end

  def loading(ets_table_id, key) do
    set_status(ets_table_id, key, :loading)
  end

  @doc """
  Set state to `:reload_loading`
  """
  @spec reload_loading(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :reload_loading | [:reload_loading]
  def reload_loading(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> reload_loading(ets_table_id, key) end)
  end

  def reload_loading(ets_table_id, key) do
    set_status(ets_table_id, key, :reload_loading)
  end

  @doc """
  Set state to `:failed`
  """
  @spec failed(atom, PayDayLoan.key() | [PayDayLoan.key()]) ::
          :failed | [:failed]
  def failed(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> failed(ets_table_id, key) end)
  end

  def failed(ets_table_id, key) do
    set_status(ets_table_id, key, :failed)
  end

  @doc """
  Remove a key from the load state table
  """
  @spec unload(atom, PayDayLoan.key() | [PayDayLoan.key()]) :: :ok | [:ok]
  def unload(ets_table_id, keys) when is_list(keys) do
    Enum.map(keys, fn key -> unload(ets_table_id, key) end)
  end

  def unload(ets_table_id, key) do
    true = :ets.delete(ets_table_id, key)
    :ok
  end

  @doc """
  Returns true if any keys are in the `:requested` or `:reload` states
  """
  @spec any_requested?(atom) :: boolean
  def any_requested?(ets_table_id) do
    # :ets.fun2ms(fn({_, :loaded}) -> true; ({_, :loading}) -> true end)
    match_spec = [
      {{:_, :requested}, [], [true]},
      {{:_, :reload}, [], [true]}
    ]

    case :ets.select(ets_table_id, match_spec, 1) do
      {[[]], _} -> false
      :"$end_of_table" -> false
      _any_other_result -> true
    end
  end

  @doc """
  Return the list of requested keys, limited to `limit` elements
  """
  @spec requested_keys(atom, pos_integer) :: [PayDayLoan.key()]
  def requested_keys(_ets_table_id, 0), do: []

  def requested_keys(ets_table_id, limit) do
    keys_in_state(ets_table_id, :requested, limit)
  end

  @doc """
  Return the list of keys in the `:reload` state, limited to `limit` elements
  """
  @spec reload_keys(atom, pos_integer) :: [PayDayLoan.key()]
  def reload_keys(_ets_table_id, 0), do: []

  def reload_keys(ets_table_id, limit) do
    keys_in_state(ets_table_id, :reload, limit)
  end

  @doc """
  Returns all elements of the table
  """
  @spec all(atom) :: [{PayDayLoan.key(), t}]
  def all(ets_table_id) do
    List.flatten(:ets.match(ets_table_id, :"$1"))
  end

  defp set_status(ets_table_id, key, status) do
    true = :ets.insert(ets_table_id, {key, status})
    status
  end

  defp keys_in_state(ets_table_id, state, limit) do
    case :ets.match(ets_table_id, {:"$1", state}, limit) do
      :"$end_of_table" -> []
      {keys, _continuation} -> List.flatten(keys)
    end
  end
end
