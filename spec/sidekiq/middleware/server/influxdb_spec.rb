require 'influxdb'

RSpec.describe Sidekiq::Middleware::Server::InfluxDB do
  let(:influxdb_client) { instance_double(InfluxDB::Client, config: config) }
  let(:config) { instance_double(InfluxDB::Config, time_precision: 's') }

  let(:job) { double(:job, perform: nil) }

  let(:clock) { double(:clock) }
  let(:t) { Time.now.to_f }

  before { expect(job).to receive(:perform) }

  it 'writes metrix to InfluxDB client' do
    expect(influxdb_client).to receive(:write_point).with("sidekiq_jobs", {
      tags: {queue: 'foo', class: 'Worker', event: 'start'},
      values: {jid: 'abc123', creation_time: t, waited: 1.0},
      timestamp: t.to_i + 1
    }, 's', nil).once

    expect(influxdb_client).to receive(:write_point).with("sidekiq_jobs", {
      tags: {queue: 'foo', class: 'Worker', event: 'finish'},
      values: {jid: 'abc123', creation_time: t, waited: 1.0, worked: 2.0, total: 3.0},
      timestamp: t.to_i + 3
    }, 's', nil).once

    allow(clock).to receive(:call).and_return(t + 1, t + 3)

    described_class
      .new(influxdb_client: influxdb_client, clock: clock)
      .call(nil, {'jid' => 'abc123', 'queue' => 'foo', 'class' => 'Worker', 'created_at' => t}, nil) { job.perform }
  end

  it 'writes to user-defined series' do
    expect(influxdb_client).to receive(:write_point) do |series, _d, _p, _r|
      expect(series).to eq('jobz')
    end.once

    described_class
      .new(influxdb_client: influxdb_client, start_events: false, series_name: 'jobz')
      .call(nil, {'created_at' => t}, nil) { job.perform }
  end

  {
     h: 1234566000,
     m: 1234567860,
     s: 1234567890,
    ms: 1234567890123,
     u: 1234567890123456,
    ns: 1234567890123456768, # seems to be floating point issue
  }
  .each do |precision, timestamp|
    context "when the supplied client is configured to use the precision '#{precision}'" do
      let(:config) { instance_double(InfluxDB::Config, time_precision: precision.to_s) }

      it "writes timestamp as #{timestamp}" do
        expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
          expect(data[:timestamp]).to eq(timestamp)
        end.once

        described_class
          .new(influxdb_client: influxdb_client, start_events: false, clock: -> { 1234567890.123456789 })
          .call(nil, {'created_at' => t}, nil) { job.perform }
      end
    end
  end

  it 'writes to user-defined retention policy' do
    expect(influxdb_client).to receive(:write_point) do |_s, _d, _p, retention_policy|
      expect(retention_policy).to eq('foo')
    end.once

    described_class
      .new(influxdb_client: influxdb_client, start_events: false, retention_policy: 'foo')
      .call(nil, {'created_at' => t}, nil) { job.perform }
  end

  it 'does not send job start events if user wants so' do
    expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
      expect(data[:tags][:event]).to eq('finish')
    end.once

    described_class
      .new(influxdb_client: influxdb_client, start_events: false)
      .call(nil, {'created_at' => t}, nil) { job.perform }
  end

  it 'mixes in user-specified tags' do
    expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
      expect(data[:tags][:foo]).to eq('bar')
    end.once

    described_class
      .new(influxdb_client: influxdb_client, start_events: false, tags: {foo: 'bar'})
      .call(nil, {'created_at' => t}, nil) { job.perform }
  end

  describe 'does not write metrics of ignored job classes' do
    it 'lets through a single class' do
      class Worker; end

      described_class
        .new(influxdb_client: influxdb_client, except: Worker)
        .call(nil, {'class' => 'Worker'}, nil) { job.perform }
    end

    it 'lets through multiple classes' do
      class Foo; end
      class Bar; end

      middleware = described_class.new(influxdb_client: influxdb_client, except: [Foo, Bar, Foo])
      middleware.call(nil, {'class' => 'Foo'}, nil) { job.perform }
      middleware.call(nil, {'class' => 'Bar'}, nil) { job.perform }
    end

    it 'lets through a single class name' do
      described_class
        .new(influxdb_client: influxdb_client, except: 'Worker')
        .call(nil, {'class' => 'Worker'}, nil) { job.perform }
    end

    it 'lets through multiple class names' do
      middleware = described_class.new(influxdb_client: influxdb_client, except: ['Foo', 'Bar', 'Foo'])
      middleware.call(nil, {'class' => 'Foo'}, nil) { job.perform }
      middleware.call(nil, {'class' => 'Bar'}, nil) { job.perform }
    end
  end

  it 'writes original job name even if it comes through ActiveJob' do
    expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
      expect(data[:tags][:class]).to eq('Worker')
    end.once

    described_class
      .new(influxdb_client: influxdb_client, start_events: false)
      .call(nil, {'class' => 'ActiveJob', 'wrapped' => 'Worker', 'created_at' => t}, nil) { job.perform }
  end

  it 'writes an error event if there was an error' do
    allow(job).to receive(:perform).and_raise(Errno::ECONNREFUSED)

    expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
      expect(data[:tags][:event]).to eq('start')
    end.once

    expect(influxdb_client).to receive(:write_point) do |_s, data, _p, _r|
      expect(data[:tags][:event]).to eq('error')
      expect(data[:tags][:error]).to eq('Errno::ECONNREFUSED')
    end.once

    expect do
      described_class
        .new(influxdb_client: influxdb_client)
        .call(nil, {'created_at' => t}, nil) { job.perform }
    end.to raise_error(Errno::ECONNREFUSED)
  end
end
