defmodule PayDayLoan.KeyCache do
  @moduledoc """
  Keeps track of which keys are known to exist in the cache source

  You shouldn't need to call these functions manually, but they
  can be useful for debugging.
  """

  # creates the underlying ETS table - gets called during startup
  @doc false
  @spec create_table(atom) :: :ok
  def create_table(table_id) do
    _ =
      :ets.new(
        table_id,
        [:set, :public, :named_table, {:read_concurrency, true}]
      )

    :ok
  end

  @doc """
  Returns true if the key exists either in the key cache or source

  Calls `callback_module.key_exists?(key)` if the key is not
  already in cache.
  """
  @spec exist?(atom, module, PayDayLoan.key()) :: boolean
  def exist?(table_id, callback_module, key) do
    in_cache?(table_id, key) || lookup?(table_id, callback_module, key)
  end

  @doc """
  Returns true if the key is in cache
  """
  @spec in_cache?(atom, PayDayLoan.key()) :: boolean
  def in_cache?(table_id, key) do
    :ets.member(table_id, key)
  end

  @doc """
  Remove a key from the cache
  """
  @spec remove(atom, PayDayLoan.key()) :: :ok
  def remove(table_id, key) do
    _ = :ets.delete(table_id, key)
    :ok
  end

  @doc """
  Calls `callback_module.key_exists?(key)`, adds key to cache if the
  callback returns true
  """
  @spec lookup?(atom, module, PayDayLoan.key()) :: boolean
  def lookup?(table_id, callback_module, key) do
    if callback_module.key_exists?(key) do
      add_to_cache(table_id, key)
    else
      false
    end
  end

  @doc """
  Add a key to the cache
  """
  @spec add_to_cache(atom, PayDayLoan.key()) :: boolean
  def add_to_cache(table_id, key) do
    :ets.insert(table_id, {key, true})
  end
end
