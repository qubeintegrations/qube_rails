# frozen_string_literal: true

require "json"

module QubeRails
  # How the JSON in qube_runs (question, links) is kept: as JSON text in a plain text column, with
  # this coder.
  #
  # Why text and not a json column: the engine has to run on PostgreSQL, MySQL and SQLite, from
  # Rails 5.2 (vendored into older apps) to 8.1, and the native types disagree. PostgreSQL has
  # json and jsonb, MySQL 5.7+ has json (MariaDB's is a longtext alias, so it comes back as a
  # String), and SQLite has no json type at all before Rails 6 maps one; what each adapter hands
  # back (a Hash, or a String to parse) differs by adapter and version. Nothing ever queries inside
  # these columns, so text and one coder behave the same everywhere, and the value is always a
  # Hash with String keys, or nil.
  module JSONCoder
    module_function

    def dump(value)
      value.nil? ? nil : JSON.generate(value)
    end

    def load(text)
      return nil if text.nil? || text == ""
      return text unless text.is_a?(String) # a json column read by its adapter already

      JSON.parse(text)
    end

    # serialize(name, coder) until Rails 7.1, serialize(name, coder:) since: the positional form
    # is deprecated in 7.1 and gone in 7.2.
    def serialize(model, *names)
      new_api = ActiveRecord.respond_to?(:gem_version) && ActiveRecord.gem_version >= Gem::Version.new("7.1")
      names.each do |name|
        if new_api
          model.serialize(name, coder: self)
        else
          model.serialize(name, self)
        end
      end
    end
  end
end
