jobs:
	bundle exec sidekiq --concurrency 1 --require ./test/jobs.rb --verbose
