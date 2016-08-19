defmodule PayDayLoanTest.Support do
  # used by tests to check that certain events happened
  defmodule LoadHistory do
    def start do
      Agent.start(fn -> [] end, name: __MODULE__)
    end

    def stop() do
      Agent.stop(__MODULE__)
    end

    def loaded([]), do: :ok
    def loaded(keys) do
      append({:loaded, keys})
      :ok
    end

    def new(key, value) do
      append({:new, [key, value]})
      :ok
    end

    def refresh(pid, key, value) do
      append({:refresh, [pid, key, value]})
      :ok
    end

    def get do
      Agent.get(__MODULE__, fn(x) -> x end)
    end

    def bulk_loads do
      get
      |> Enum.filter(&is_bulk_load?/1)
    end

    def loads do
      get
      |> Enum.filter(&is_load?/1)
    end

    def news do
      get
      |> Enum.filter(&is_new?/1)
    end

    def refreshes do
      get
      |> Enum.filter(&is_refresh?/1)
    end

    defp append(value) do
      Agent.update(__MODULE__, fn(so_far) -> so_far ++ [value] end)
    end

    defp is_bulk_load?({:loaded, keys})
    when is_list(keys) and length(keys) > 1 do
      true
    end
    defp is_bulk_load?(_), do: false

    defp is_load?({:loaded, keys})
    when is_list(keys) and length(keys) > 0 do
      true
    end
    defp is_load?(_), do: false

    defp is_new?({:new, _}), do: true
    defp is_new?(_), do: false

    defp is_refresh?({:refresh, _}), do: true
    defp is_refresh?(_), do: false
  end
end
