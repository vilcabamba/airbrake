require 'airbrake-ruby'

namespace :airbrake do
  desc 'Verify your gem installation by sending a test exception'
  task test: (:environment if defined?(Rails)) do
    unless Airbrake.configured?
      raise Airbrake::Error, 'airbrake-ruby is not configured'
    end

    require 'pp'

    response = Airbrake.notify_sync('Exception from the test Rake task')
    if response['code']
      puts <<-ERROR.gsub(/^\s+\|/, '')
        |Couldn't send a test exception:
        |#{response['type']}: #{response['message']} (#{response['code']})
        |
        |Possible problems:
        |  1. Project ID or project key is incorrect
        |  2. Exception was ignored due to misconfigured filters
        |  3. The environment this task runs in is ignored by Airbrake
      ERROR
    else
      puts <<-OUTPUT.gsub(/^\s+\|/, '')
        |A test exception was sent to Airbrake.
        |Find it here: #{response['url']}
      OUTPUT
    end
  end

  desc 'Notify Airbrake of a new deploy'
  task :deploy do
    unless Airbrake.configured?
      raise Airbrake::Error, 'airbrake-ruby is not configured'
    end

    if defined?(Rails)
      initializer = Rails.root.join('config', 'initializers', 'airbrake.rb')

      # Avoid loading the environment to speed up the deploy task and try guess
      # the initializer file location.
      if initializer.exist? && !Airbrake.configured?
        load(initializer)
      else
        Rake::Task[:environment].invoke
      end
    end

    deploy_params = {
      environment: ENV['ENVIRONMENT'],
      username: ENV['USERNAME'],
      revision: ENV['REVISION'],
      repository: ENV['REPOSITORY'],
      version: ENV['VERSION']
    }
    promise = Airbrake.create_deploy(deploy_params)
    promise.then do
      puts "The #{deploy_params[:environment]} environment was deployed."
    end
    promise.rescue { |error| abort(error) }
  end

  desc 'Install a Heroku deploy hook to notify Airbrake of deploys'
  task :install_heroku_deploy_hook do
    app = ENV['HEROKU_APP']

    config = Bundler.with_clean_env do
      `heroku config --shell#{ " --app #{app}" if app }`
    end

    heroku_env = config.each_line.with_object({}) do |line, h|
      h.merge!(Hash[*line.rstrip.split("\n").flat_map { |v| v.split('=', 2) }])
    end

    id = heroku_env['AIRBRAKE_PROJECT_ID']
    key = heroku_env['AIRBRAKE_API_KEY']

    exit!(1) if [id, key].any?(&:nil?)

    unless (env = heroku_env['RAILS_ENV'])
      env = 'production'
      puts "Airbrake couldn't identify your app's environment, so the '#{env}'" \
           " environment will be used."
    end

    unless (repo = ENV['REPOSITORY_URL'])
      repo = `git remote get-url origin 2>/dev/null`.chomp
      if repo.empty?
        puts "Airbrake couldn't identify your app's repository."
      else
        puts "Airbrake couldn't identify your app's repository, so the " \
             "'origin' remote url '#{repo}' will be used."
      end
    end

    url = "https://airbrake.io/api/v3/projects/#{id}/heroku-deploys?key=#{key}"
    url << "&environment=#{env}"
    url << "&repository=#{repo}" unless repo.empty?

    command = %(heroku addons:create deployhooks:http --url="#{url}")
    command << " --app #{app}" if app

    puts "$ #{command}"
    Bundler.with_clean_env { puts `#{command}` }
  end
end
