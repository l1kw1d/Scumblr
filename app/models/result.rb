#     Copyright 2014 Netflix, Inc.
#
#     Licensed under the Apache License, Version 2.0 (the "License");
#     you may not use this file except in compliance with the License.
#     You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.



class Result < ActiveRecord::Base
  belongs_to :status

  has_many :search_results
  has_many :searches, :through=>:search_results
  has_many :taggings, as: :taggable, :dependent => :delete_all
  has_many :tags, through: :taggings

  has_many :result_flags
  has_many :flags, through: :result_flags
  has_many :stages, through: :result_flags
  has_many :subscribers, as: :subscribable

  has_many :events, as: :eventable

  has_many :result_attachments

  belongs_to :user

  #attr_accessible :title, :url, :status_id

  validates :url, uniqueness: true
  validates :url, presence: true
  validates_format_of :url, with: /\A#{URI::regexp}\z/

  serialize :metadata, Hash

  acts_as_commentable

  attr_accessor :current_user

  before_create :set_status
  before_save :create_events
  

  def set_status
    if(self.status.blank?)
      self.status = Status.find_by_default(true)
    end
  end

  def create_events
    event = self.events.build(action: self.new_record? ? "Created" : "Updated", user_id: self.current_user.try(:id) )
    self.changes.each do |k, v|
      if(k.ends_with?("_id") && (association = self.class.reflect_on_all_associations.select{|a| a.try(:foreign_key) == k}).present?)
        associated_values = association.first.klass.where(id: [ v[0], v[1] ])
        event.event_changes.build(field: association.first.class_name, 
          old_value: associated_values.select{|a| a.id == v[0]}.try(:first).to_s, 
          new_value: associated_values.select{|a| a.id == v[1]}.try(:first).to_s,
          old_value_key: v[0], 
          new_value_key: v[1],
          value_class: association.first.klass.to_s,
          )
      elsif(self.class.serialized_attributes.keys.include?(k))

        event.event_changes.build(field: k.to_s, old_value: v[0].to_s, new_value: v[1].to_s)
        HashDiff.diff(v[0] || {},v[1]).each do |diff|
          field_name = (k.to_s + ": " + diff[1].to_s).titlecase
          if(diff[0] == "-")
            event.event_changes.build(field: field_name, old_value: diff[2].to_s, new_value: nil)
          elsif(diff[0] == "+")
            event.event_changes.build(field: field_name, old_value: nil, new_value: diff[2].to_s)
          elsif(diff[0] == "~")
            event.event_changes.build(field: field_name, old_value: diff[2].to_s, new_value: diff[3].to_s)
          end
        end
      else
        event.event_changes.build(field: k.to_s.titlecaser, old_value: v[0].to_s, new_value: v[1].to_s)
      end  
    end
  end


  def to_s
    "Result #{id}"
  end

  def self.tagged_with(name)
    Tagging.where({:tag_id=>Tag.find_all_by_name(name).map(&:id), :taggable_type=> "Result"}).map{|tagging| tagging.taggable}
  end

  def self.tag_counts
    Tag.select("tags.*, count(taggings.tag_id) as count").
      joins(:taggings).group("taggings.tag_id")
  end

  def tag_list
    tags.map(&:name).join(", ")
  end

  def tag_list=(names)
    self.tags = names.split(",").map do |n|
      tag = Tag.where("lower(name) like lower(?)",n.strip).first_or_initialize
      tag.name = n.strip if tag.new_record?
      tag.save if tag.changed?
      tag
    end
  end

  def create_attachment_from_url(url)
    attachment = self.result_attachments.new
    attachment.attachment_remote_url = url
    attachment.save
  end

  def create_attachment_from_sketchy(url)
    Rails.logger.debug "Getting screenshot #{self.id} "
    sketchy_url = Rails.configuration.try(:sketchy_url)
    if(sketchy_url.blank?)
      Rails.logger.error "No sketch URL configured."
      return
    end

    uri = URI.parse(sketchy_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 75
    http.use_ssl = Rails.configuration.try(:sketchy_use_ssl) || false
    if(Rails.configuration.try(:sketchy_use_ssl) && (Rails.configuration.try(:sketchy_verify_ssl) == false || Rails.configuration.try(:sketchy_verify_ssl) == "false"))
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end 

    request = Net::HTTP::Post.new(uri.request_uri)
    request.add_field "Content-Type", "application/json"
    if(Rails.configuration.try(:sketchy_access_token).present?)
      request.add_field "Token", Rails.configuration.try(:sketchy_access_token).to_s
    end

    request.body = {:url=>url, :callback=>Rails.application.routes.url_helpers.update_screenshot_result_url(self.id)}.to_json

    Rails.logger.debug "Sending request #{request.body.inspect}"
    attempts = 0
    begin
      response = http.request(request)
      Rails.logger.debug "Response received #{response.code}"


      if(response.code == "200" || response.code == "201")
        Rails.logger.debug "Sketch OK"

      else
        raise RuntimeError
      end

    rescue RuntimeError, EOFError => e
      Rails.logger.error "#{e.inspect}"
      if(attempts < 3)
        attempts += 1
        message = "Retrying due to response from sketchy. #{response.try(:code)}"
        Rails.logger.error message
        retry
      else
        message = "Final failure. Bad response from sketchy. #{response.try(:code)} #{response.try(message)} (#{url})"
        Rails.logger.error message
      end
    end

  rescue StandardError=>e
    Rails.logger.error "Error communicating with sketchy: #{e.inspect} #{e.message}: #{e.backtrace}"
  end




  def has_attachment?
    return (self.result_attachments.count > 0)
  end

  def self.perform_search(q)
    result = Result.includes(:status, :result_attachments).search(q)
    result.sorts = 'created_at desc' if result.sorts.empty?
    result
  end



end
