require 'net/http'
require 'uri'
require 'json'
require 'openssl'

# State withholding form URLs — states with their own forms
# Excludes: no-income-tax states (AK, FL, NV, NH, SD, TN, TX, WA, WY)
# Excludes: states that accept federal W-4 only (CO, MT, NM, ND, UT)
STATES = {
  'AL' => { name: 'Alabama A-4', url: 'https://www.revenue.alabama.gov/wp-content/uploads/2017/05/A-4.pdf' },
  'AZ' => { name: 'Arizona A-4', url: 'https://azdor.gov/sites/default/files/media/FORM_A-4.pdf' },
  'AR' => { name: 'Arkansas AR4EC', url: 'https://www.dfa.arkansas.gov/images/uploads/incomeTaxOffice/AR4EC.pdf' },
  'CA' => { name: 'California DE 4', url: 'https://edd.ca.gov/siteassets/files/pdf_pub_ctr/de4.pdf' },
  'CT' => { name: 'Connecticut CT-W4', url: 'https://portal.ct.gov/-/media/drs/forms/2024/withholdingforms/ct-w4_1224.pdf' },
  'DC' => { name: 'DC D-4', url: 'https://otr.cfo.dc.gov/sites/default/files/dc/sites/otr/publication/attachments/2024_D-4_Fill_In.pdf' },
  'DE' => { name: 'Delaware W-4', url: 'https://revenue.delaware.gov/wp-content/uploads/sites/tax/2020/02/Delaware_W4_Employee_Withholding.pdf' },
  'GA' => { name: 'Georgia G-4', url: 'https://dor.georgia.gov/sites/dor.georgia.gov/files/related_files/document/TSD/Form/2024_G-4.pdf' },
  'HI' => { name: 'Hawaii HW-4', url: 'https://files.hawaii.gov/tax/forms/2023/hw4_i.pdf' },
  'IA' => { name: 'Iowa IA W-4', url: 'https://tax.iowa.gov/sites/default/files/2023-01/IAW4%2844-019%29.pdf' },
  'ID' => { name: 'Idaho ID W-4', url: 'https://tax.idaho.gov/wp-content/uploads/forms/EFO00307/EFO00307_12-19-2023.pdf' },
  'IL' => { name: 'Illinois IL-W-4', url: 'https://tax.illinois.gov/content/dam/soi/en/web/tax/forms/withholding/documents/il-w-4.pdf' },
  'IN' => { name: 'Indiana WH-4', url: 'https://www.in.gov/dor/files/WH-4.pdf' },
  'KS' => { name: 'Kansas K-4', url: 'https://www.ksrevenue.gov/pdf/k-4.pdf' },
  'KY' => { name: 'Kentucky K-4', url: 'https://revenue.ky.gov/Forms/Form%20K-4.pdf' },
  'LA' => { name: 'Louisiana L-4', url: 'https://revenue.louisiana.gov/Forms/ForIndividuals/R-1300(L4).pdf' },
  'MA' => { name: 'Massachusetts M-4', url: 'https://www.mass.gov/doc/form-m-4-massachusetts-employees-withholding-exemption-certificate/download' },
  'MD' => { name: 'Maryland MW507', url: 'https://www.marylandtaxes.gov/forms/current_forms/MW507.pdf' },
  'ME' => { name: 'Maine W-4ME', url: 'https://www.maine.gov/revenue/sites/maine.gov.revenue/files/inline-files/w-4me_2024.pdf' },
  'MI' => { name: 'Michigan MI-W4', url: 'https://www.michigan.gov/taxes/-/media/Project/Websites/taxes/Forms/2024/Withholding/MI-W4.pdf' },
  'MN' => { name: 'Minnesota W-4MN', url: 'https://www.revenue.state.mn.us/sites/default/files/2024-01/w-4mn_24.pdf' },
  'MO' => { name: 'Missouri MO W-4', url: 'https://dor.mo.gov/forms/MO%20W-4.pdf' },
  'MS' => { name: 'Mississippi 89-350', url: 'https://www.dor.ms.gov/sites/default/files/Forms/Individual/Withholding/89-350-23-1.pdf' },
  'NC' => { name: 'North Carolina NC-4', url: 'https://www.ncdor.gov/documents/nc-4-employee-withholding-allowance-certificate' },
  'NE' => { name: 'Nebraska W-4N', url: 'https://revenue.nebraska.gov/sites/revenue.nebraska.gov/files/doc/tax-forms/f_w4n.pdf' },
  'NJ' => { name: 'New Jersey NJ-W4', url: 'https://www.nj.gov/treasury/taxation/pdf/current/njw4.pdf' },
  'NY' => { name: 'New York IT-2104', url: 'https://www.tax.ny.gov/pdf/current_forms/it/it2104_fill_in.pdf' },
  'OH' => { name: 'Ohio IT-4', url: 'https://tax.ohio.gov/static/forms/ohio_individual/individual/2024/it-4.pdf' },
  'OK' => { name: 'Oklahoma OK-W-4', url: 'https://oklahoma.gov/content/dam/ok/en/tax/documents/forms/withholding/OK-W-4.pdf' },
  'OR' => { name: 'Oregon OR-W-4', url: 'https://www.oregon.gov/dor/forms/FormsPubs/form-or-w-4_101-402_2024.pdf' },
  'PA' => { name: 'Pennsylvania REV-419', url: 'https://www.revenue.pa.gov/FormsandPublications/FormsforIndividuals/PIT/Documents/rev-419.pdf' },
  'RI' => { name: 'Rhode Island RI W-4', url: 'https://tax.ri.gov/sites/g/files/xkgbur541/files/forms/W-4_2024.pdf' },
  'SC' => { name: 'South Carolina SC W-4', url: 'https://dor.sc.gov/forms-site/Forms/SC_W4_2024.pdf' },
  'VA' => { name: 'Virginia VA-4', url: 'https://www.tax.virginia.gov/sites/default/files/taxforms/withholding/any/va-4-any.pdf' },
  'VT' => { name: 'Vermont W-4VT', url: 'https://tax.vermont.gov/sites/tax/files/documents/W-4VT.pdf' },
  'WI' => { name: 'Wisconsin WT-4', url: 'https://www.revenue.wi.gov/DOR%20Publications/pb166.pdf' },
  'WV' => { name: 'West Virginia WV/IT-104', url: 'https://tax.wv.gov/Documents/TaxForms/it104.pdf' },
}

def download_pdf(url, max_redirects = 5)
  raise "Too many redirects" if max_redirects <= 0
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 15
  http.read_timeout = 30
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  request = Net::HTTP::Get.new(uri.request_uri)
  request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
  request['Accept'] = 'application/pdf,*/*'

  response = http.request(request)

  case response
  when Net::HTTPRedirection
    location = response['location']
    location = URI.join(url, location).to_s unless location.start_with?('http')
    download_pdf(location, max_redirects - 1)
  when Net::HTTPSuccess
    response.body
  else
    raise "HTTP #{response.code}: #{response.message}"
  end
end

results = {}
account = Account.first

STATES.each do |code, info|
  print "#{code} (#{info[:name]})... "
  begin
    pdf_data = download_pdf(info[:url])

    if pdf_data.nil? || pdf_data.length < 1000
      puts "SKIP (too small: #{pdf_data&.length || 0} bytes)"
      results[code] = { status: 'skip', reason: 'too small' }
      next
    end

    # Create template
    template = Template.create!(
      account: account,
      name: "State Withholding: #{info[:name]}",
      fields: [
        { 'name' => 'Employee Signature', 'type' => 'signature', 'required' => true,
          'areas' => [{ 'page' => 0, 'x' => 0.05, 'y' => 0.85, 'w' => 0.4, 'h' => 0.05 }] },
        { 'name' => 'Date', 'type' => 'date', 'required' => true,
          'areas' => [{ 'page' => 0, 'x' => 0.55, 'y' => 0.85, 'w' => 0.2, 'h' => 0.05 }] }
      ],
      schema: [{ 'attachment_uuid' => SecureRandom.uuid, 'name' => "#{info[:name]}.pdf" }],
      external_id: "state-withholding-#{code.downcase}"
    )

    # Attach PDF via ActiveStorage
    template.documents.attach(
      io: StringIO.new(pdf_data),
      filename: "#{code.downcase}-withholding.pdf",
      content_type: 'application/pdf'
    )

    # Update schema with actual attachment UUID
    blob = template.documents.last.blob
    template.update!(schema: [{ 'attachment_uuid' => blob.key, 'name' => "#{info[:name]}.pdf" }])

    puts "OK (template #{template.id}, #{pdf_data.length} bytes)"
    results[code] = { status: 'ok', template_id: template.id, size: pdf_data.length }
  rescue => e
    puts "FAIL (#{e.message[0..80]})"
    results[code] = { status: 'fail', error: e.message[0..200] }
  end
end

puts "\n=== RESULTS ==="
puts JSON.pretty_generate(results)
puts "\n=== SUMMARY ==="
ok = results.count { |_, v| v[:status] == 'ok' }
fail_count = results.count { |_, v| v[:status] == 'fail' }
skip = results.count { |_, v| v[:status] == 'skip' }
puts "OK: #{ok}, Failed: #{fail_count}, Skipped: #{skip}"
