# frozen_string_literal: true

require "json"

module QubeRails
  # A rows field (add_transaction's question about missing records): the same columns asked of
  # each row, posted as data[<field>][<row key>][<column>]. columns are FieldViews (one per
  # column, for the header), rows RowViews, and bulk one CellView per column for the
  # "Set selected" bar (its field nil when that column has no bulk control).
  class RowsView
    attr_reader :name, :label, :input_name, :search_url, :columns, :rows, :bulk

    def initialize(field, input_name:, search_url:)
      @name = field["name"].to_s
      @label = (field["label"] || @name).to_s
      @input_name = input_name
      @search_url = search_url
      declared = Array(field["columns"]).select { |c| c.is_a?(Hash) }
      @columns = declared.map { |column| column_field(column) }
      @rows = Array(field["rows"]).select { |r| r.is_a?(Hash) }.map { |row| RowView.new(row, declared, self) }
      @bulk = declared.map { |column| CellView.new(column: column["name"].to_s, field: bulk_field(column), bulk: true) }
    end

    # A column's control for one row (context :cell), or nil for a column the row doesn't ask.
    def cell_field(column, row_key, disabled)
      col = column["name"].to_s
      FieldView.new(name: col, type: FieldView.type_of(column, record_type: "search"),
                    label: column["label"] || col, input_name: "#{input_name}[#{row_key}][#{col}]",
                    required: column["required"] == true, options: FieldView.options_of(column),
                    kind: column["kind"], search_url: search_url, search_field: "#{name}.#{col}",
                    row_key: row_key, when_values: when_of(column), context: :cell, disabled: disabled)
    end

    def when_of(column)
      column["when"].is_a?(Hash) ? column["when"] : {}
    end

    private

    def column_field(column)
      col = column["name"].to_s
      FieldView.new(name: col, type: FieldView.type_of(column, record_type: "search"), label: column["label"] || col,
                    required: column["required"] == true, options: FieldView.options_of(column),
                    kind: column["kind"], search_url: search_url, search_field: "#{name}.#{col}",
                    when_values: when_of(column), context: :cell)
    end

    # A select for an enum column; a search for a record column whose kind is the same on every
    # row; nothing for the rest.
    def bulk_field(column)
      col = column["name"].to_s
      type = if column["enum"].is_a?(Array) && !column["enum"].empty? then "select"
             elsif column["type"] == "record" && !column["kind"].to_s.empty? then "search"
             end
      return nil unless type

      FieldView.new(name: col, type: type, label: column["label"] || col, options: FieldView.options_of(column),
                    kind: column["kind"], search_url: search_url, search_field: "#{name}.#{col}", context: :bulk)
    end
  end

  # One row: a record, its cells (one per column), and the values it already has (values_json
  # for data-qube-values, which a column's "when" reads with the row's answers).
  class RowView
    attr_reader :key, :label, :detail, :values, :cells

    def initialize(row, declared, rows)
      @key = row["key"].to_s
      @label = (row["label"] || @key).to_s
      @detail = row["detail"].to_s.strip.empty? ? nil : row["detail"].to_s
      @values = row["values"].is_a?(Hash) ? row["values"] : {}
      asks = Array(row["columns"]).map(&:to_s)
      @cells = declared.map do |column|
        col = column["name"].to_s
        when_values = rows.when_of(column)
        shown = applies?(when_values)
        if asks.include?(col)
          CellView.new(column: col, field: rows.cell_field(column, @key, !shown), when_values: when_values, shown: shown)
        else
          CellView.new(column: col, preset: preset_text(column, @values[col]), when_values: when_values, shown: shown)
        end
      end
    end

    def values_json
      values.to_json
    end

    private

    # Before the user picks anything, a column shows when its "when" holds for the row's values.
    def applies?(when_values)
      when_values.all? { |col, allowed| Array(allowed).include?(values[col]) }
    end

    # A value the row already has, shown as its enum label when it has one.
    def preset_text(column, value)
      entry = Array(column["enum"]).find { |e| e.is_a?(Hash) && e["value"] == value }
      entry ? entry["label"].to_s : value.to_s
    end
  end

  # One cell of a rows table: a field to fill (field), or what the row already has (preset). A
  # cell whose "when" doesn't hold yet is hidden (shown false: data-qube-hidden, its input
  # disabled). A "Set selected" cell is bulk.
  class CellView
    attr_reader :column, :field, :preset, :when, :shown, :bulk

    def initialize(column:, field: nil, preset: nil, when_values: {}, shown: true, bulk: false)
      @column = column
      @field = field
      @preset = preset
      @when = when_values
      @shown = shown
      @bulk = bulk
    end

    def when_json
      self.when.to_json
    end

    def hidden?
      !shown
    end
  end
end
