# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

class SMIMECertificate < ApplicationModel
  validates :fingerprint, uniqueness: true

  def self.parse(raw)
    OpenSSL::X509::Certificate.new(raw.gsub(/(?:TRUSTED\s)?(CERTIFICATE---)/, '\1'))
  end

  # Search for the certificate of the given sender email address
  #
  # @example
  #  certificate = SMIMECertificates.for_sender_email_address('some1@example.com')
  #  # => #<SMIMECertificate:0x00007fdd4e27eec0...
  #
  # @return [SMIMECertificate, nil] The found certificate record or nil
  def self.for_sender_email_address(address)
    downcased_address = address.downcase
    where.not(private_key: nil).find_each.detect do |certificate|
      certificate.email_addresses.include?(downcased_address)
    end
  end

  # Search for certificates of the given recipients email addresses
  #
  # @example
  #  certificates = SMIMECertificates.for_recipipent_email_addresses!(['some1@example.com', 'some2@example.com'])
  #  # => [#<SMIMECertificate:0x00007fdd4e27eec0...
  #
  # @raise [ActiveRecord::RecordNotFound] if there are recipients for which no certificate could be found
  #
  # @return [Array<SMIMECertificate>] The found certificate records
  def self.for_recipipent_email_addresses!(addresses)
    certificates        = []
    remaining_addresses = addresses.map(&:downcase)
    find_each do |certificate|

      # intersection of both lists
      cerfiticate_for = certificate.email_addresses & remaining_addresses
      next if cerfiticate_for.blank?

      certificates.push(certificate)

      # subtract found recipient(s)
      remaining_addresses -= cerfiticate_for

      # end loop if no addresses are remaining
      break if remaining_addresses.blank?
    end

    return certificates if remaining_addresses.blank?

    raise ActiveRecord::RecordNotFound, "Can't find S/MIME encryption certificates for: #{remaining_addresses.join(', ')}"
  end

  def public_key=(string)
    cert = self.class.parse(string)

    self.subject       = cert.subject
    self.doc_hash      = cert.subject.hash.to_s(16)
    self.fingerprint   = OpenSSL::Digest.new('SHA1', cert.to_der).to_s
    self.modulus       = cert.public_key.n.to_s(16)
    self.not_before_at = cert.not_before
    self.not_after_at  = cert.not_after
    self.raw           = cert.to_s
  end

  def parsed
    @parsed ||= self.class.parse(raw)
  end

  def email_addresses
    @email_addresses ||= begin
      subject_alt_name = parsed.extensions.detect { |extension| extension.oid == 'subjectAltName' }
      if subject_alt_name.blank?
        Rails.logger.warn <<~TEXT.squish
          SMIMECertificate with ID #{id} has no subjectAltName
          extension and therefore no email addresses assigned.
          This makes it useless in terms of S/MIME. Please check.
        TEXT

        []
      else
        # ["IP Address:192.168.7.23", "IP Address:192.168.7.42", "email:jd@example.com", "email:John.Doe@example.com", "dirName:dir_sect"]
        entries = subject_alt_name.value.split(/,\s?/)
        # ["email:jd@example.com", "email:John.Doe@example.com"]
        email_address_entries = entries.select { |entry| entry.start_with?('email') }
        # ["jd@example.com", "John.Doe@example.com"]
        email_address_entries.map! { |entry| entry.split(':')[1] }
        # ["jd@example.com", "john.doe@example.com"]
        email_address_entries.map!(&:downcase)
      end
    end
  end

  def expired?
    !Time.zone.now.between?(not_before_at, not_after_at)
  end
end
