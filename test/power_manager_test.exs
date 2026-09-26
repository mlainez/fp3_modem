defmodule Fp3Modem.PowerManagerTest do
  use ExUnit.Case, async: false

  alias Fp3Modem.PowerManager

  @moduletag capture_log: true

  # Stand-in for QMI.Driver: same registered name, replies to DMS calls
  # from a scripted list of results (the real driver answers
  # {:error, {:service_not_found, 2}} until the modem announces DMS).
  defmodule FakeDriver do
    use GenServer

    def start_link({name, replies, test_pid}) do
      GenServer.start_link(__MODULE__, {replies, test_pid}, name: name)
    end

    @impl true
    def init({replies, test_pid}), do: {:ok, %{replies: replies, test: test_pid}}

    @impl true
    def handle_call({:call, _client_id, request, _timeout}, _from, state) do
      [reply | rest] = state.replies
      send(state.test, {:qmi_call, request.service_id, reply})

      case reply do
        :crash -> exit(:boom)
        reply -> {:reply, reply, %{state | replies: rest}}
      end
    end
  end

  defp unique_ifname, do: "rmnet_test#{System.unique_integer([:positive])}"

  defp init!(opts) do
    {:ok, state} = PowerManager.init(opts)
    state
  end

  defp start_fake(ifname, replies) do
    name = Module.concat(VintageNetQMI.qmi_name(ifname), "Driver")
    {:ok, _} = FakeDriver.start_link({name, replies, self()})
  end

  describe "init/1" do
    test "accepts the documented options" do
      assert {:ok, state} =
               PowerManager.init(ifname: "rmnet0", watchdog_timeout: 120_000)

      assert state.ifname == "rmnet0"
      assert state.qmi == VintageNetQMI.qmi_name("rmnet0")
      assert state.retry_min_ms == 500
      assert state.retry_max_ms == 10_000
      assert state.online_task == nil
    end

    test "requires a non-empty string :ifname" do
      assert_raise ArgumentError, fn -> PowerManager.init([]) end
      assert_raise ArgumentError, fn -> PowerManager.init(ifname: "") end
      assert_raise ArgumentError, fn -> PowerManager.init(ifname: :rmnet0) end
    end

    test "validates retry options" do
      assert_raise ArgumentError, fn -> PowerManager.init(ifname: "rmnet0", retry_min_ms: 0) end

      assert_raise ArgumentError, fn ->
        PowerManager.init(ifname: "rmnet0", retry_min_ms: 100, retry_max_ms: 50)
      end
    end
  end

  test "backoff/3 doubles up to the cap" do
    assert Enum.map(0..5, &PowerManager.backoff(&1, 500, 5_000)) ==
             [500, 1_000, 2_000, 4_000, 5_000, 5_000]
  end

  describe "callback return shapes (no QMI running)" do
    test "power_on / start_powering_off / power_off / handle_info" do
      state = init!(ifname: unique_ifname())

      assert {:ok, on_state, 600_000} = PowerManager.power_on(state)
      task = on_state.online_task
      assert Process.alive?(task)

      assert {:ok, off_state, 5_000} = PowerManager.start_powering_off(on_state)
      assert off_state.online_task == nil
      refute Process.alive?(task)

      assert {:ok, ^off_state, 2_000} = PowerManager.power_off(off_state)
      assert {:noreply, ^off_state} = PowerManager.handle_info(:anything, off_state)
    end

    test "power_on replaces a previous online task" do
      state = init!(ifname: unique_ifname())
      {:ok, s1, _} = PowerManager.power_on(state)
      {:ok, s2, _} = PowerManager.power_on(s1)
      refute Process.alive?(s1.online_task)
      assert Process.alive?(s2.online_task)
      PowerManager.power_off(s2)
    end
  end

  describe "set_mode/2" do
    test "returns an error when the QMI driver isn't running" do
      qmi = VintageNetQMI.qmi_name(unique_ifname())
      assert {:error, {:exit, _}} = PowerManager.set_mode(qmi, :online)
    end

    test "passes through the driver's service_not_found before DMS is announced" do
      ifname = unique_ifname()
      start_fake(ifname, [{:error, {:service_not_found, 2}}, :ok])
      qmi = VintageNetQMI.qmi_name(ifname)

      assert PowerManager.set_mode(qmi, :online) == {:error, {:service_not_found, 2}}
      assert PowerManager.set_mode(qmi, :online) == :ok
    end

    test "turns driver exits into errors" do
      ifname = unique_ifname()
      start_fake(ifname, [:crash])
      Process.flag(:trap_exit, true)

      assert {:error, {:exit, _}} =
               PowerManager.set_mode(VintageNetQMI.qmi_name(ifname), :online)
    end
  end

  test "power_on retries until the modem goes online" do
    ifname = unique_ifname()

    start_fake(ifname, [
      {:error, {:service_not_found, 2}},
      {:error, {:service_not_found, 2}},
      {:error, :internal},
      :ok
    ])

    state = init!(ifname: ifname, retry_min_ms: 10, retry_max_ms: 20)

    {:ok, state, _} = PowerManager.power_on(state)
    ref = Process.monitor(state.online_task)

    assert_receive {:qmi_call, 2, {:error, {:service_not_found, 2}}}, 1_000
    assert_receive {:qmi_call, 2, {:error, :internal}}, 1_000
    assert_receive {:qmi_call, 2, :ok}, 1_000
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
  end
end
