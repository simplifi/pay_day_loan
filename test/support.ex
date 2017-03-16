defmodule PayDayLoanTest.Support do
  def wait_for(pred_callback) do
    Patiently.wait_for!(pred_callback, dwell: 1, max_tries: 100)
  end
end
