require "./spec_helper"

# Covers the job-eviction guarantee from 4671f5f: the cap never evicts
# a RUNNING job while finished ones exist — a client polling an evicted
# running job would see a 404 while docker is still working (#32).
{% unless flag?(:demo_mode) %}
  describe "ComposeJobs eviction" do
    it "never evicts a running job while finished ones can go" do
      ComposeJobs::JOBS.clear

      # Fill the cap with finished jobs, plus one long-running one.
      49.times do |i|
        job = ComposeJobs::Job.new("finished-#{i}", "finished")
        job.finish(0)
        ComposeJobs::JOBS[job.id] = job
      end
      running = ComposeJobs::Job.new("running-spec", "running")
      ComposeJobs::JOBS[running.id] = running

      # One more job: prune_locked must evict the oldest FINISHED job,
      # not the running one. The command cannot run; the job records
      # the failure via its own error handling.
      new_id = ComposeJobs.start("spec", [["/nonexistent-spec-binary"]])

      ComposeJobs::JOBS["running-spec"]?.should_not be_nil
      ComposeJobs::JOBS[new_id]?.should_not be_nil
      finished_left = ComposeJobs::JOBS.keys.count(&.starts_with?("finished-"))
      finished_left.should eq(48) # exactly one finished job evicted
      ComposeJobs::JOBS.size.should be <= ComposeJobs::MAX_JOBS
    ensure
      ComposeJobs::JOBS.clear
    end
  end
{% end %}
