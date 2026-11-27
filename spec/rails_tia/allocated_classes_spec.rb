RSpec.describe 'CRuby allocation tracking', if: RUBY_ENGINE == 'ruby' do
  it 'keeps distinct collectors and intervals independent across GC compaction' do
    require 'rails_tia/native_extension'
    require RailsTia::ALLOCATION_EXTENSION
    form = Class.new
    first = RailsTia::AllocatedClasses.new.start
    second = RailsTia::AllocatedClasses.new.start
    3.times { form.new }
    GC.compact
    first.stop
    expect(first.drain.count(form)).to eq(1)
    expect(second.drain.count(form)).to eq(1)
    Thread.new { form.new }.join
    expect(second.drain).to include(form)
    expect(first.drain).not_to include(form)
  ensure
    first&.stop
    second&.stop
  end
end
