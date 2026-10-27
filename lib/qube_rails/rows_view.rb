# frozen_string_literal: true

require "json"

module QubeRails
  # A rows field (add_transaction's question about missing records): the same columns asked of
  # each row, posted as data[<field>][<row key>][<column>]. Shown as one block per record, its
  # fields stacked: columns are FieldViews (one per column), rows RowViews. set_all is the column
  # the "Set all to:" line sets on every row (a segmented one asked by two rows or more), or nil.
  class RowsView
    attr_reader :name, :label, :input_name, :search_url, :columns, :rows

    def initialize(field, input_name:, search_url:)
      @name = field["name"].to_s
      @label = (field["label"] || @name).to_s
      @input_name = input_name
      @search_url = search_url
      declared = Array(field["columns"]).select { |c| c.is_a?(Hash) }
      @columns = declared.map { |column| column_field(column) }
      @rows = Array(field["rows"]).select { |r| r.is_a?(Hash) }.each_with_index.map do |row, n|
        RowView.new(row, declared, self, n)
      end
    end

    # A column's control for one row (context :cell). Shown or not, it isn't required in the
    # markup while hidden (the script sets required as it shows it).
    def cell_field(column, row_key, row_index, shown)
      col = column["name"].to_s
      FieldView.new(name: col, type: FieldView.type_of(column, record_type: "search"),
                    label: column["label"] || col, input_name: "#{input_name}[#{row_key}][#{col}]",
                    dom_id: "qube-#{input_name.gsub(/[^A-Za-z0-9]+/, "-")}#{row_index}-#{col}".squeeze("-"),
                    required: column["required"] == true && shown, options: FieldView.options_of(column),
                    kind: column["kind"], search_url: search_url, search_field: "#{name}.#{col}",
                    row_key: row_key, when_values: when_of(column), context: :cell, disabled: !shown)
    end

    def when_of(column)
      column["when"].is_a?(Hash) ? column["when"] : {}
    end

    # The column "Set all to:" sets, with its options: the first segmented one two rows or more ask.
    def set_all
      return nil if rows.size < 2

      columns.find do |column|
        column.type == "select" && column.options.size.between?(1, 3) &&
          rows.count { |row| row.cells.any? { |cell| cell.column == column.name && cell.field } } >= 2
      end
    end

    private

    def column_field(column)
      col = column["name"].to_s
      FieldView.new(name: col, type: FieldView.type_of(column, record_type: "search"), label: column["label"] || col,
                    required: column["required"] == true, options: FieldView.options_of(column),
                    kind: column["kind"], search_url: search_url, search_field: "#{name}.#{col}",
                    when_values: when_of(column), context: :cell)
    end
  end

  # One record: its cells (the columns it asks, and a value it already has), and the values it
  # already has (values_json for data-qube-values, which a column's "when" reads with the row's
  # answers). A column the row neither asks nor has a value for has no cell.
  class RowView
    attr_reader :key, :label, :detail, :values, :cells, :index

    def initialize(row, declared, rows, index = 0)
      @key = row["key"].to_s
      @label = (row["label"] || @key).to_s
      @detail = row["detail"].to_s.strip.empty? ? nil : row["detail"].to_s
      @values = row["values"].is_a?(Hash) ? row["values"] : {}
      @index = index
      asks = Array(row["columns"]).map(&:to_s)
      @cells = declared.filter_map do |column|
        col = column["name"].to_s
        when_values = rows.when_of(column)
        shown = applies?(when_values)
        required = column["required"] == true
        label = (column["label"] || col).to_s
        if asks.include?(col)
          CellView.new(column: col, label: label, field: rows.cell_field(column, @key, index, shown),
                       when_values: when_values, shown: shown, required: required)
        elsif !@values[col].to_s.empty?
          CellView.new(column: col, label: label, preset: preset_text(column, @values[col]), when_values: when_values,
                       shown: shown)
        end
      end
    end

    def values_json
      values.to_json
    end

    # The segmented cells (the row's choice, such as create or use), then the rest.
    def segmented_cells
      cells.select(&:segmented?)
    end

    def field_cells
      cells.reject(&:segmented?)
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

  # One field of a row: a field to fill (field), or what the row already has (preset, read-only).
  # A cell whose "when" doesn't hold yet is hidden (shown false: hidden, data-qube-hidden, its input
  # disabled and not required). required is the column's, which the script restores as it shows it.
  class CellView
    attr_reader :column, :label, :field, :preset, :when, :shown, :required

    def initialize(column:, label: nil, field: nil, preset: nil, when_values: {}, shown: true, required: false)
      @column = column
      @label = label || column
      @field = field
      @preset = preset
      @when = when_values
      @shown = shown
      @required = required
    end

    def when_json
      self.when.to_json
    end

    def hidden?
      !shown
    end

    def segmented?
      !field.nil? && field.segmented?
    end
  end
end
