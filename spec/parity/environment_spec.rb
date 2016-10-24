require File.join(File.dirname(__FILE__), '..', '..', 'lib', 'parity')

RSpec.describe Parity::Environment do
  before do
    allow(Kernel).to receive(:exec).and_return(true)
    allow(Kernel).to receive(:system).and_return(true)
  end

  it "passes through arguments to heroku-cli with correct quoting" do
    execute_command_with_quotable_arguments

    expect(Kernel).to have_received(:exec).with(*psql_count)
  end

  describe "returned value" do
    context "when the executed command does not explicitly return true" do
      it "returns false" do
        allow(Kernel).to receive(:exec).with(*psql_count).and_return(nil)

        result = execute_command_with_quotable_arguments

        expect(result).to eq(false)
      end
    end

    context "when deploy was successful with no pending migrations" do
      it "returns true" do
        stub_is_a_rails_app
        stub_pending_migrations(true)

        expect(deploy_to_production).to eq(true)
      end
    end

    context "when deploy was not successful" do
      it "returns false" do
        stub_is_a_rails_app
        allow(Kernel).to receive(:system).with(git_push).and_return(false)

        expect(deploy_to_production).to eq(false)
      end
    end
  end

  it "backs up the database" do
    Parity::Environment.new("production", ["backup"]).run

    expect(Kernel).to have_received(:system).with(heroku_backup)
  end

  it "connects to the Heroku app when $PWD does not match the app name" do
    backup = stub_parity_backup
    stub_git_remote(base_name: "parity-integration", environment: "staging")

    Parity::Environment.new("staging", ["restore", "production"]).run

    expect(Parity::Backup).
      to have_received(:new).
      with(
        from: "production",
        to: "staging",
        additional_args: "--confirm parity-integration-staging",
      )
    expect(backup).to have_received(:restore)
  end

  describe "database restores" do
    it "restores backups from production to staging" do
      backup = stub_parity_backup
      stub_git_remote(environment: "staging")

      Parity::Environment.new("staging", ["restore", "production"]).run

      expect(Parity::Backup).
        to have_received(:new).
        with(
          from: "production",
          to: "staging",
          additional_args: "--confirm parity-staging",
        )
      expect(backup).to have_received(:restore)
    end

    it "restores using restore-from" do
      backup = stub_parity_backup
      stub_git_remote(environment: "staging")

      Parity::Environment.new("staging", ["restore-from", "production"]).run

      expect(Parity::Backup).
        to have_received(:new).
        with(
          from: "production",
          to: "staging",
          additional_args: "--confirm parity-staging",
        )
      expect(backup).to have_received(:restore)
    end

    context "with a confirmation argument and a non-production environment" do
      it "passes the confirm argument" do
        backup = stub_parity_backup
        stub_git_remote(environment: "staging")

        Parity::Environment.new("staging", ["restore", "production"]).run

        expect(Parity::Backup).to have_received(:new).
          with(
            from: "production",
            to: "staging",
            additional_args: "--confirm parity-staging",
          )
        expect(backup).to have_received(:restore)
      end
    end

    it "restores backups from production to development" do
      backup = stub_parity_backup

      Parity::Environment.new("development", ["restore", "production"]).run

      expect(Parity::Backup).to have_received(:new).
        with(from: "production", to: "development", additional_args: "")
      expect(backup).to have_received(:restore)
    end

    it "restores backups from staging to development" do
      backup = stub_parity_backup

      Parity::Environment.new("development", ["restore", "staging"]).run

      expect(Parity::Backup).to have_received(:new).
        with(from: "staging", to: "development", additional_args: "")
      expect(backup).to have_received(:restore)
    end

    it "does not allow restoring backups into production" do
      stub_parity_backup
      stub_git_remote
      allow($stdout).to receive(:puts)

      Parity::Environment.new("production", ["restore", "staging"]).run

      expect(Parity::Backup).not_to have_received(:new)
      expect($stdout).to have_received(:puts).
        with("Parity does not support restoring backups into your production "\
            "environment. Use `--force` to override.")
    end

    it "restores backups into production if forced" do
      backup = stub_parity_backup

      Parity::Environment.new("production", ["restore", "staging", "--force"]).run

      expect(Parity::Backup).to have_received(:new).
        with(from: "staging", to: "production", additional_args: "--force")
      expect(backup).to have_received(:restore)
    end
  end

  describe "special commands" do
    it "opens the remote console" do
      Parity::Environment.new("production", ["console"]).run

      expect(Kernel).to have_received(:system).with(heroku_console)
    end

    it "tails logs with any additional arguments" do
      Parity::Environment.new("production", ["tail", "--ps", "web"]).run

      expect(Kernel).to have_received(:system).with(tail)
    end

    it "opens a Redis session connected to the environment's Redis service" do
      allow(Open3).to receive(:capture3).and_return(open3_redis_url_fetch_result)

      Parity::Environment.new("production", ["redis_cli"]).run

      expect(Kernel).to have_received(:system).with(
        "redis-cli",
        "-h",
        "landshark.redistogo.com",
        "-p",
        "90210",
        "-a",
        "abcd1234efgh5678"
      )
      expect(Open3).
        to have_received(:capture3).
        with(fetch_redis_url("REDIS_URL")).
        once
    end
  end

  describe "database migration on deploy" do
    it "deploys the application and runs migrations when required" do
      stub_is_a_rails_app
      stub_pending_migrations(true)

      deploy_to_production

      expect(Kernel).
        to have_received(:system).
        with(check_for_no_pending_migrations).
        ordered
      expect(Kernel).to have_received(:system).with(git_push).ordered
      expect(Kernel).to have_received(:system).with(migrate).ordered
    end

    it "deploys the application and skips migrations when not required" do
      stub_is_a_rails_app
      stub_pending_migrations(false)

      it_does_not_run_migrations
    end

    context "when deploying to a non-production environment" do
      it "compares against HEAD to check for pending migrations" do
        stub_is_a_rails_app

        deploy_to_staging

        expect(Kernel).
          to have_received(:system).
          with(
            check_for_no_pending_migrations(
              compare_with: "HEAD",
              environment: "staging",
            )
          ).ordered
      end
    end

    context "when no db/migrate directory is present" do
      it "does not run migrations" do
        stub_migration_path_check(false)
        stub_rakefile_check(true)

        it_does_not_run_migrations
      end
    end

    context "when the deploy fails" do
      it "does not run migrations" do
        stub_is_a_rails_app
        stub_pending_migrations(true)
        allow(Kernel).to receive(:system).with(git_push).and_return(false)

        it_does_not_run_migrations
      end
    end

    context "when no Rakefile is present" do
      it "does not run migrations" do
        stub_migration_path_check(true)
        stub_rakefile_check(false)

        it_does_not_run_migrations
      end
    end
  end

  it "deploys feature branches to staging's master for evaluation" do
    deploy_to_staging

    expect(Kernel).to have_received(:system).with(git_push_feature_branch)
  end

  def heroku_backup
    "heroku pg:backups capture --remote production"
  end

  def heroku_console
    "heroku run rails console --remote production"
  end

  def git_push
    "git push production master"
  end

  def git_push_feature_branch
    "git push staging HEAD:master --force"
  end

  def check_for_no_pending_migrations(compare_with: "master", environment: "production")
      %{
        git fetch #{environment} &&
        git diff --quiet #{environment}/master..#{compare_with} -- db/migrate
      }
  end

  def migrate
      %{
        heroku run rake db:migrate --remote production &&
        heroku restart --remote production
      }
  end

  def tail
    "heroku logs --tail --ps web --remote production"
  end

  def redis_cli
    "redis-cli -h landshark.redistogo.com -p 90210 -a abcd1234efgh5678"
  end

  def fetch_redis_url(env_variable)
    "heroku config:get #{env_variable} --remote production"
  end

  def open3_redis_url_fetch_result
    [
      "redis://redistogo:abcd1234efgh5678@landshark.redistogo.com:90210/\n",
      "",
      ""
    ]
  end

  def psql_count
    [
      "heroku",
      "pg:psql",
      "-c",
      "select count(*) from users;",
      "--remote", "production"
    ]
  end

  def stub_is_a_rails_app
    stub_rakefile_check(true)
    stub_migration_path_check(true)
  end

  def stub_rakefile_check(result)
    allow(File).to receive(:exists?).with("Rakefile").and_return(result)
  end

  def stub_migration_path_check(result)
    path_stub = spy("Pathname", directory?: result)
    allow(Pathname).to receive(:new).with("db").and_return(path_stub)

    path_stub
  end

  def stub_git_remote(base_name: "parity", environment: "staging")
    allow(Open3).
      to receive(:capture3).
      with("heroku info --remote #{environment}").
      and_return(
        [
          "=== #{base_name}-#{environment}\nAddOns: blahblahblah",
          "",
          {},
        ],
      )
  end

  def stub_parity_backup
    backup = instance_double(Parity::Backup, restore: nil)
    allow(Parity::Backup).to receive(:new).and_return(backup)

    backup
  end

  def it_does_not_run_migrations
    deploy_to_production

    expect(Kernel).not_to have_received(:system).with(migrate)
  end

  def deploy_to(environment)
    Parity::Environment.new(environment, ["deploy"]).run
  end

  def deploy_to_production
    deploy_to("production")
  end

  def deploy_to_staging
    deploy_to("staging")
  end

  def stub_pending_migrations(result)
    allow(Kernel).
      to receive(:system).
      with(check_for_no_pending_migrations).
      and_return(!result)
  end

  def execute_command_with_quotable_arguments
    Parity::Environment.new(
      "production",
      ["pg:psql", "-c", "select count(*) from users;"],
    ).run
  end
end
