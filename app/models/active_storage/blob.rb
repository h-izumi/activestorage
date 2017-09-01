# frozen_string_literal: true

# A blob is a record that contains the metadata about a file and a key for where that file resides on the service.
# Blobs can be created in two ways:
#
# 1. Subsequent to the file being uploaded server-side to the service via <tt>create_after_upload!</tt>.
# 2. Ahead of the file being directly uploaded client-side to the service via <tt>create_before_direct_upload!</tt>.
#
# The first option doesn't require any client-side JavaScript integration, and can be used by any other back-end
# service that deals with files. The second option is faster, since you're not using your own server as a staging
# point for uploads, and can work with deployments like Heroku that do not provide large amounts of disk space.
#
# Blobs are intended to be immutable in as-so-far as their reference to a specific file goes. You're allowed to
# update a blob's metadata on a subsequent pass, but you should not update the key or change the uploaded file.
# If you need to create a derivative or otherwise change the blob, simply create a new blob and purge the old one.
class ActiveStorage::Blob < ActiveRecord::Base
  self.table_name = "active_storage_blobs"

  has_secure_token :key
  store :metadata, coder: JSON

  class_attribute :service

  class << self
    # You can used the signed ID of a blob to refer to it on the client side without fear of tampering.
    # This is particularly helpful for direct uploads where the client-side needs to refer to the blob
    # that was created ahead of the upload itself on form submission.
    #
    # The signed ID is also used to create stable URLs for the blob through the BlobsController.
    def find_signed(id)
      find ActiveStorage.verifier.verify(id, purpose: :blob_id)
    end

    # Returns a new, unsaved blob instance after the +io+ has been uploaded to the service.
    def build_after_upload(io:, filename:, content_type: nil, metadata: nil)
      new.tap do |blob|
        blob.filename     = filename
        blob.content_type = content_type
        blob.metadata     = metadata

        blob.upload io
      end
    end

    # Returns a saved blob instance after the +io+ has been uploaded to the service. Note, the blob is first built,
    # then the +io+ is uploaded, then the blob is saved. This is done this way to avoid uploading (which may take
    # time), while having an open database transaction.
    def create_after_upload!(io:, filename:, content_type: nil, metadata: nil)
      build_after_upload(io: io, filename: filename, content_type: content_type, metadata: metadata).tap(&:save!)
    end

    # Returns a saved blob _without_ uploading a file to the service. This blob will point to a key where there is
    # no file yet. It's intended to be used together with a client-side upload, which will first create the blob
    # in order to produce the signed URL for uploading. This signed URL points to the key generated by the blob.
    # Once the form using the direct upload is submitted, the blob can be associated with the right record using
    # the signed ID.
    def create_before_direct_upload!(filename:, byte_size:, checksum:, content_type: nil, metadata: nil)
      create! filename: filename, byte_size: byte_size, checksum: checksum, content_type: content_type, metadata: metadata
    end
  end


  # Returns a signed ID for this blob that's suitable for reference on the client-side without fear of tampering.
  # It uses the framework-wide verifier on <tt>ActiveStorage.verifier</tt>, but with a dedicated purpose.
  def signed_id
    ActiveStorage.verifier.generate(id, purpose: :blob_id)
  end

  # Returns the key pointing to the file on the service that's associated with this blob. The key is in the
  # standard secure-token format from Rails. So it'll look like: XTAPjJCJiuDrLk3TmwyJGpUo. This key is not intended
  # to be revealed directly to the user. Always refer to blobs using the signed_id or a verified form of the key.
  def key
    # We can't wait until the record is first saved to have a key for it
    self[:key] ||= self.class.generate_unique_secure_token
  end

  # Returns an ActiveStorage::Filename instance of the filename that can be
  # queried for basename, extension, and a sanitized version of the filename
  # that's safe to use in URLs.
  def filename
    ActiveStorage::Filename.new(self[:filename])
  end

  # Returns true if the content_type of this blob is in the image range, like image/png.
  def image?
    content_type.start_with?("image")
  end

  # Returns true if the content_type of this blob is in the audio range, like audio/mpeg.
  def audio?
    content_type.start_with?("audio")
  end

  # Returns true if the content_type of this blob is in the video range, like video/mp4.
  def video?
    content_type.start_with?("video")
  end

  # Returns true if the content_type of this blob is in the text range, like text/plain.
  def text?
    content_type.start_with?("text")
  end

  # Returns an ActiveStorage::Variant instance with the set of +transformations+
  # passed in. This is only relevant for image files, and it allows any image to
  # be transformed for size, colors, and the like. Example:
  #
  #   avatar.variant(resize: "100x100").processed.service_url
  #
  # This will create and process a variant of the avatar blob that's constrained to a height and width of 100.
  # Then it'll upload said variant to the service according to a derivative key of the blob and the transformations.
  #
  # Frequently, though, you don't actually want to transform the variant right away. But rather simply refer to a
  # specific variant that can be created by a controller on-demand. Like so:
  #
  #   <%= image_tag url_for(Current.user.avatar.variant(resize: "100x100")) %>
  #
  # This will create a URL for that specific blob with that specific variant, which the ActiveStorage::VariantsController
  # can then produce on-demand.
  def variant(transformations)
    ActiveStorage::Variant.new(self, ActiveStorage::Variation.new(transformations))
  end


  # Returns the URL of the blob on the service. This URL is intended to be short-lived for security and not used directly
  # with users. Instead, the +service_url+ should only be exposed as a redirect from a stable, possibly authenticated URL.
  # Hiding the +service_url+ behind a redirect also gives you the power to change services without updating all URLs. And
  # it allows permanent URLs that redirect to the +service_url+ to be cached in the view.
  def service_url(expires_in: 5.minutes, disposition: :inline)
    service.url key, expires_in: expires_in, disposition: "#{disposition}; #{filename.parameters}", filename: filename, content_type: content_type
  end

  # Returns a URL that can be used to directly upload a file for this blob on the service. This URL is intended to be
  # short-lived for security and only generated on-demand by the client-side JavaScript responsible for doing the uploading.
  def service_url_for_direct_upload(expires_in: 5.minutes)
    service.url_for_direct_upload key, expires_in: expires_in, content_type: content_type, content_length: byte_size, checksum: checksum
  end

  # Returns a Hash of headers for +service_url_for_direct_upload+ requests.
  def service_headers_for_direct_upload
    service.headers_for_direct_upload key, filename: filename, content_type: content_type, content_length: byte_size, checksum: checksum
  end

  # Uploads the +io+ to the service on the +key+ for this blob. Blobs are intended to be immutable, so you shouldn't be
  # using this method after a file has already been uploaded to fit with a blob. If you want to create a derivative blob,
  # you should instead simply create a new blob based on the old one.
  #
  # Prior to uploading, we compute the checksum, which is sent to the service for transit integrity validation. If the
  # checksum does not match what the service receives, an exception will be raised. We also measure the size of the +io+
  # and store that in +byte_size+ on the blob record.
  #
  # Normally, you do not have to call this method directly at all. Use the factory class methods of +build_after_upload+
  # and +create_after_upload!+.
  def upload(io)
    self.checksum  = compute_checksum_in_chunks(io)
    self.byte_size = io.size

    service.upload(key, io, checksum: checksum)
  end

  # Downloads the file associated with this blob. If no block is given, the entire file is read into memory and returned.
  # That'll use a lot of RAM for very large files. If a block is given, then the download is streamed and yielded in chunks.
  def download(&block)
    service.download key, &block
  end


  # Deletes the file on the service that's associated with this blob. This should only be done if the blob is going to be
  # deleted as well or you will essentially have a dead reference. It's recommended to use the +#purge+ and +#purge_later+
  # methods in most circumstances.
  def delete
    service.delete key
  end

  # Deletes the file on the service and then destroys the blob record. This is the recommended way to dispose of unwanted
  # blobs. Note, though, that deleting the file off the service will initiate a HTTP connection to the service, which may
  # be slow or prevented, so you should not use this method inside a transaction or in callbacks. Use +#purge_later+ instead.
  def purge
    delete
    destroy
  end

  # Enqueues an ActiveStorage::PurgeJob job that'll call +purge+. This is the recommended way to purge blobs when the call
  # needs to be made from a transaction, a callback, or any other real-time scenario.
  def purge_later
    ActiveStorage::PurgeJob.perform_later(self)
  end

  private
    def compute_checksum_in_chunks(io)
      Digest::MD5.new.tap do |checksum|
        while chunk = io.read(5.megabytes)
          checksum << chunk
        end

        io.rewind
      end.base64digest
    end
end
