asset_directory = File.expand_path('../../../../assets', __FILE__)
asset_file_paths = Dir.glob(File.join(asset_directory, '*.*'))
asset_file_names = asset_file_paths.map{|e| File.basename(e) }

describe asset_file_names do
  it 'should contain .js files' do
    expect(asset_file_names).to include('message-bus.js')
  end
end

asset_file_paths.each do | path |
  describe "Asset file #{File.basename(path).inspect}" do
    it 'should be encodable as UTF8' do
      binary_data = File.open(path, 'rb'){|f| f.read }
      encode_block = -> { binary_data.encode(Encoding::UTF_8) }
      expect(encode_block).not_to raise_error
    end
  end
end