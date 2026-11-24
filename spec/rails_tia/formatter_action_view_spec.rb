require 'rails_tia/formatter'

RSpec.describe 'ActionView formatter lifecycle' do
  before do
    allow(Coverage).to receive(:result).and_return({})
    allow(RailsTia::RailsSupport).to receive(:available?).and_return(true)
    allow(RailsTia::ActionViewSupport).to receive(:available?).and_return(true)
  end

  [
    [{ 'enabled' => false }, false, false],
    [{ 'enabled' => true, 'action_view' => false }, true, false],
    [{ 'enabled' => true, 'active_record' => false }, false, true],
    [{ 'enabled' => true }, true, true],
    [{}, false, false],
  ].each do |options, ar_enabled, av_enabled|
    it "respects independent collectors with rails=#{options.inspect}" do
      hide_const('Rails') if options.empty?
      allow(RailsTia).to receive(:config).and_return(RailsTia::Configuration.new({ 'rails' => options }))
      [[RailsTia::RailsSupport, ar_enabled], [RailsTia::ActionViewSupport, av_enabled]].each do |klass, enabled|
        if enabled
          support = instance_double(klass, flush: [], unsubscribe: nil)
          expect(klass).to receive(:new).once.and_return(support)
          expect(support).to receive(:subscribe).once.and_return(support)
          expect(support).to receive(:unsubscribe).once
        else
          expect(klass).not_to receive(:new)
        end
      end
      formatter = RailsTia::Formatter.new(nil)
      allow(formatter.instance_variable_get(:@map)).to receive(:dump)
      2.times { formatter.start(nil) }
      formatter.stop(Struct.new(:failed_examples).new([]))
    end
  end

  it 'unsubscribes both collectors even when writing the map fails, then allows reinitialization' do
    allow(RailsTia).to receive(:config).and_return(RailsTia::Configuration.new({ 'rails' => { 'enabled' => true } }))
    [RailsTia::RailsSupport, RailsTia::ActionViewSupport].each do |klass|
      support = instance_double(klass, flush: [])
      expect(klass).to receive(:new).twice.and_return(support)
      expect(support).to receive(:subscribe).twice.and_return(support)
      expect(support).to receive(:unsubscribe).twice
    end
    formatter = RailsTia::Formatter.new(nil)
    allow(formatter.instance_variable_get(:@map)).to receive(:dump).and_raise(IOError, 'write failed')
    2.times do
      formatter.start(nil)
      expect { formatter.stop(Struct.new(:failed_examples).new([])) }.to raise_error(IOError, 'write failed')
    end
  end
end
