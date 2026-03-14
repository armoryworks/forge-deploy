require 'json'

STATES = {
  'AR' => 'Arkansas AR4EC',
  'CA' => 'California DE 4',
  'KS' => 'Kansas K-4',
  'MA' => 'Massachusetts M-4',
  'NJ' => 'New Jersey NJ-W4',
  'NY' => 'New York IT-2104',
  'OR' => 'Oregon OR-W-4',
  'PA' => 'Pennsylvania REV-419',
  'VA' => 'Virginia VA-4',
  'VT' => 'Vermont W-4VT',
  'WI' => 'Wisconsin WT-4',
}

user = User.first
account = Account.first
results = {}

STATES.each do |code, name|
  pdf_path = "/tmp/#{code}.pdf"
  unless File.exist?(pdf_path)
    puts "#{code}: SKIP (no PDF)"
    next
  end

  print "#{code} (#{name})... "
  begin
    template = Template.new(
      account: account,
      author: user,
      name: "State Withholding: #{name}",
      fields: [
        { 'name' => 'Employee Signature', 'type' => 'signature', 'required' => true,
          'areas' => [{ 'page' => 0, 'x' => 0.05, 'y' => 0.85, 'w' => 0.4, 'h' => 0.05 }] },
        { 'name' => 'Date', 'type' => 'date', 'required' => true,
          'areas' => [{ 'page' => 0, 'x' => 0.55, 'y' => 0.85, 'w' => 0.2, 'h' => 0.05 }] }
      ],
      external_id: "state-withholding-#{code.downcase}"
    )

    pdf_data = File.binread(pdf_path)
    template.documents.attach(
      io: StringIO.new(pdf_data),
      filename: "#{code.downcase}-withholding.pdf",
      content_type: 'application/pdf'
    )

    blob_key = template.documents.last.blob.key
    template.schema = [{ 'attachment_uuid' => blob_key, 'name' => "#{name}.pdf" }]
    template.save!

    puts "OK (template #{template.id})"
    results[code] = template.id
  rescue => e
    puts "FAIL (#{e.message[0..100]})"
  end
end

puts "\n=== STATE => DOCUSEAL TEMPLATE ID MAPPING ==="
puts JSON.pretty_generate(results)
