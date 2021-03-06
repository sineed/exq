defmodule Exq.Enqueuer.Server do
  @moduledoc """
  The Enqueuer is responsible for enqueueing jobs into Redis. It can
  either be called directly by the client, or instantiated as a standalone process.

  It also deals with getting current stats for the UI / API.  (TODO: Split this out).

  It supports enqueuing immediate jobs, or scheduling jobs in the future.

  ## Initialization:
    * `:name` - Name of target registered process
    * `:namespace` - Redis namespace to store all data under. Defaults to "exq".
    * `:queues` - Array of currently active queues (TODO: Remove, I suspect it's not needed).
    * `:redis` - pid of Redis process.
    * `:scheduler_poll_timeout` - How often to poll Redis for scheduled / retry jobs.
  """

  require Logger

  alias Exq.Support.Config
  alias Exq.Redis.Connection
  alias Exq.Redis.JobQueue
  alias Exq.Redis.JobStat
  import Exq.Redis.JobQueue, only: [full_key: 2]
  use GenServer

  defmodule State do
    defstruct redis: nil, namespace: nil, redis_owner: false
  end

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  def start_link(opts \\ []) do
    redis_name = opts[:redis] || Exq.Redis.Supervisor.client_name(opts[:name])
    opts = Keyword.merge(opts, [redis: redis_name])
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

##===========================================================
## gen server callbacks
##===========================================================

  def init(opts) do
    namespace = Keyword.get(opts, :namespace, Config.get(:namespace, "exq"))
    case Process.whereis(opts[:redis]) do
      nil -> Exq.Redis.Supervisor.start_link(opts)
      _ -> :ok
    end
    state = %State{redis: opts[:redis],
                   redis_owner: true,
                   namespace: namespace}
    {:ok, state}
  end

  def handle_cast({:enqueue, from, queue, worker, args}, state) do
    response = JobQueue.enqueue(state.redis, state.namespace, queue, worker, args)
    GenServer.reply(from, response)
    {:noreply, state}
  end

  def handle_cast({:enqueue_at, from, queue, time, worker, args}, state) do
    response = JobQueue.enqueue_at(state.redis, state.namespace, queue, time, worker, args)
    GenServer.reply(from, response)
    {:noreply, state}
  end

  def handle_cast({:enqueue_in, from, queue, offset, worker, args}, state) do
    response = JobQueue.enqueue_in(state.redis, state.namespace, queue, offset, worker, args)
    GenServer.reply(from, response)
    {:noreply, state}
  end

  def handle_call({:enqueue, queue, worker, args}, _from, state) do
    response = JobQueue.enqueue(state.redis, state.namespace, queue, worker, args)
    {:reply, response, state}
  end

  def handle_call({:enqueue_at, queue, time, worker, args}, _from, state) do
    response = JobQueue.enqueue_at(state.redis, state.namespace, queue, time, worker, args)
    {:reply, response, state}
  end

  def handle_call({:enqueue_in, queue, offset, worker, args}, _from, state) do
    response = JobQueue.enqueue_in(state.redis, state.namespace, queue, offset, worker, args)
    {:reply, response, state}
  end

  # WebUI Stats callbacks

  def handle_call(:processes, _from, state) do
    processes = JobStat.processes(state.redis, state.namespace)
    {:reply, {:ok, processes}, state, 0}
  end

  def handle_call(:busy, _from, state) do
    count = JobStat.busy(state.redis, state.namespace)
    {:reply, {:ok, count}, state, 0}
  end

  def handle_call({:stats, key}, _from, state) do
    count = get_count(state.redis, state.namespace, key)
    {:reply, {:ok, count}, state, 0}
  end

  def handle_call({:stats, key, date}, _from, state) do
    count = get_count(state.redis, state.namespace, "#{key}:#{date}")
    {:reply, {:ok, count}, state, 0}
  end

  def handle_call(:queues, _from, state) do
    queues = list_queues(state.redis, state.namespace)
    {:reply, {:ok, queues}, state, 0}
  end

  def handle_call(:failed, _from, state) do
   jobs = list_failed(state.redis, state.namespace)
   {:reply, {:ok, jobs}, state, 0}
  end

  def handle_call(:retries, _from, state) do
   jobs = list_retry(state.redis, state.namespace)
   {:reply, {:ok, jobs}, state, 0}
  end

  def handle_call(:jobs, _from, state) do
    queues = list_queues(state.redis, state.namespace)
    jobs = for q <- queues, do: {q, list_jobs(state.redis, state.namespace, q)}
    {:reply, {:ok, jobs}, state, 0}
  end
  def handle_call({:jobs, :scheduled}, _from, state) do
    jobs = list_jobs(state.redis, state.namespace, :scheduled)
    {:reply, {:ok, jobs}, state, 0}
  end
  def handle_call({:jobs, queue}, _from, state) do
    jobs = list_jobs(state.redis, state.namespace, queue)
    {:reply, {:ok, jobs}, state, 0}
  end

  def handle_call(:queue_size, _from, state) do
    queues = list_queues(state.redis, state.namespace)
    sizes = for q <- queues, do: {q, queue_size(state.redis, state.namespace, q)}
    {:reply, {:ok, sizes}, state, 0}
  end
  def handle_call({:queue_size, :scheduled}, _from, state) do
    size = queue_size(state.redis, state.namespace, :scheduled)
    {:reply, {:ok, size}, state, 0}
  end
  def handle_call({:queue_size, queue}, _from, state) do
    size = queue_size(state.redis, state.namespace, queue)
    {:reply, {:ok, size}, state, 0}
  end

  def handle_call({:find_failed, jid}, _from, state) do
    {:ok, job, idx} = JobStat.find_failed(state.redis, state.namespace, jid)
    {:reply, {:ok, job, idx}, state, 0}
  end

  def handle_call({:find_job, queue, jid}, _from, state) do
    {:ok, job, idx} = JobQueue.find_job(state.redis, state.namespace, jid, queue)
    {:reply, {:ok, job, idx}, state, 0}
  end

  def handle_call({:find_scheduled_job, jid}, _from, state) do
    {:ok, job, idx} = JobQueue.find_job(state.redis, state.namespace, jid, :scheduled)
    {:reply, {:ok, job, idx}, state, 0}
  end

  def handle_call({:remove_queue, queue}, _from, state) do
    JobStat.remove_queue(state.redis, state.namespace, queue)
    {:reply, {:ok}, state, 0}
  end

  def handle_call({:remove_failed, jid}, _from, state) do
    JobStat.remove_failed(state.redis, state.namespace, jid)
    {:reply, {:ok}, state, 0}
  end

  def handle_call(:clear_failed, _from, state) do
    JobStat.clear_failed(state.redis, state.namespace)
    {:reply, {:ok}, state, 0}
  end

  def handle_call(:clear_processes, _from, state) do
    JobStat.clear_processes(state.redis, state.namespace)
    {:reply, {:ok}, state, 0}
  end

  def handle_call(:realtime_stats, _from, state) do
    {:ok, failures, successes} = JobStat.realtime_stats(state.redis, state.namespace)
    {:reply, {:ok, failures, successes}, state, 0}
  end

  def terminate(_reason, state) do
    if state.redis_owner do
      case Process.whereis(state.redis) do
        nil -> :ignore
        pid -> Redix.stop(pid)
      end
    end
    :ok
  end

  # Internal Functions
  def get_count(redis, namespace, key) do
    case Connection.get!(redis, JobQueue.full_key(namespace, "stat:#{key}")) do
      :undefined ->
        0
      count ->
        count
    end
  end

  def list_queues(redis, namespace) do
    Connection.smembers!(redis, full_key(namespace, "queues"))
  end

  def list_jobs(redis, namespace, :scheduled) do
    Connection.zrangebyscorewithscore!(redis, full_key(namespace, "schedule"))
  end
  def list_jobs(redis, namespace, queue) do
    Connection.lrange!(redis, full_key(namespace, "queue:#{queue}"))
  end

  def list_failed(redis, namespace) do
    Connection.zrange!(redis, full_key(namespace, "dead"))
  end

  def list_retry(redis, namespace) do
    Connection.zrange!(redis, full_key(namespace, "retry"))
  end

  def queue_size(redis, namespace, :scheduled) do
    Connection.zcard!(redis, full_key(namespace, "schedule"))
  end
  def queue_size(redis, namespace, :retry) do
    Connection.zcard!(redis, full_key(namespace, "retry"))
  end
  def queue_size(redis, namespace, queue) do
    Connection.llen!(redis, full_key(namespace, "queue:#{queue}"))
  end

end
