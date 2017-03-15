defmodule PayDayLoan.CacheStateManager do
  @moduledoc """
  Keeps track of which keys are cached.
  """

  # this should get called by the supervisor during startup
  @doc false
  @spec create_table(atom) :: :ok
  def create_table(ets_table_id) do
    _ = :ets.new(
      ets_table_id,
      [:public, :named_table, {:read_concurrency, true}]
    )
    :ok
  end

  @doc """
  Perform Enum.reduce on the ETS table
  """
  @spec reduce(atom, term, (({PayDayLoan.key, pid}, term) -> term)) :: term
  def reduce(ets_table_id, acc0, reducer)
  when is_function(reducer, 2) do
    :ets.foldl(
      fn({k, v}, acc) ->
        case resolve_value(v, k, ets_table_id) do
          {:ok, resolved_v} -> reducer.({k, resolved_v}, acc)
          {:error, :not_found} -> acc
        end
      end,
      acc0,
      ets_table_id
    )
  end

  @doc """
  Returns the number of cached keys
  """
  @spec size(atom) :: non_neg_integer
  def size(ets_table_id) do
    :ets.info(ets_table_id, :size)
  end

  @doc """
  Returns a list of all cached keys
  """
  @spec all_keys(atom) :: [PayDayLoan.key]
  def all_keys(ets_table_id) do
    reduce(ets_table_id, [], fn({k, _pid}, acc) -> [k | acc] end)
  end

  @doc """
  Returns a list of all cached values
  """
  @spec all_values(atom) :: [term]
  def all_values(ets_table_id) do
    reduce(ets_table_id, [], fn({_k, v}, acc) -> [v | acc] end)
  end

  @doc """
  Get the value corresponding to the given key

  If the value is a process that is not alive, deletes the entry and returns
  `{:error, :not_found}`.
  """
  @spec get_value(atom, PayDayLoan.key) :: {:ok, term} | {:error, :not_found}
  def get_value(ets_table_id, key) do
    case lookup(ets_table_id, key) do
      {:ok, pre_resolve_value} -> resolve_value(pre_resolve_value, key, ets_table_id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Add a value to the cache and monitor it if it is a pid.
  """
  @spec put(atom, PayDayLoan.key, term) :: :ok
  def put(id, key, value) do
    :ets.insert(id, {key, value})
    if is_pid(value) do
      GenServer.cast(id, {:monitor, value})
    end
    :ok
  end

  @doc """
  Look up a pid without checking if the pid is alive
  """
  @spec lookup(atom, PayDayLoan.key) :: {:ok, pid} | {:error, :not_found}
  def lookup(ets_table_id, key) do
    case :ets.lookup(ets_table_id, key) do
      [{_key, pid}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Remove a value from cache
  """
  @spec delete_value(atom, term) :: :ok
  def delete_value(ets_table_id, value) do
    true = :ets.match_delete(ets_table_id, {:'_', value})
    :ok
  end

  @doc """
  Remove a key from cache
  """
  @spec delete_key(atom, PayDayLoan.key) :: :ok
  def delete_key(ets_table_id, key) do
    true = :ets.delete(ets_table_id, key)
    :ok
  end

  defp resolve_value(cb, key, _ets_table_id) when is_function(cb, 1) do
    cb.(key)
  end
  defp resolve_value(pid, _key, ets_table_id) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      :ok = delete_value(ets_table_id, pid)
      {:error, :not_found}
    end
  end
  defp resolve_value(value, _key, _ets_table_id), do: {:ok, value}
end
