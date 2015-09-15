require "true"
require "clip"

module SeedDump
  class Perform

    def initialize
      @opts = {}
      @ar_options = {}
      @indent = ""
      @models = []
      @last_record = []
      @seed_rb = ""
      @id_set_string = ""
      @model_dir = 'app/models/**/*.rb'
    end

    def setup(env)
      # config
      @opts['verbose'] = env["VERBOSE"].true? || env['VERBOSE'].nil?
      @opts['debug'] = env["DEBUG"].true?
      @opts['with_id'] = env["WITH_ID"].true?
      @opts['timestamps'] = env["TIMESTAMPS"].true? || env["TIMESTAMPS"].nil?
      @opts['no-data'] = env['NO_DATA'].true?
      @opts['without_protection'] = env['WITHOUT_PROTECTION'].true? || (env['WITHOUT_PROTECTION'].nil? && @opts['timestamps'])
      @opts['skip_callbacks'] = env['SKIP_CALLBACKS'].true?
      @opts['models']  = env['MODELS'] || (env['MODEL'] ? env['MODEL'] : "")
      @opts['file']    = env['FILE'] || "#{Rails.root}/db/seeds.rb"
      @opts['append']  = (env['APPEND'].true? && File.exists?(@opts['file']) )
      @opts['max']     = env['MAX'] && env['MAX'].to_i > 0 ? env['MAX'].to_i : nil
      @ar_options      = env['LIMIT'].to_i > 0 ? { :limit => env['LIMIT'].to_i } : {}
      @indent          = " " * (env['INDENT'].nil? ? 2 : env['INDENT'].to_i)
      @opts['models']  = @opts['models'].split(',')
      @opts['habtms']   = (env['HABTMS'] && env['HABTMS'].split(',')) || []
      @opts['schema']  = env['PG_SCHEMA']
      @opts['model_dir']  = env['MODEL_DIR'] || @model_dir
      @opts['create_method']  = env['CREATE_METHOD'] || 'create'
    end

    def initializeModels
      @opts['models'].each do |model|
        begin
          model.constantize
          @models.push model
        rescue NameError
          puts "couldn't find model #{model}"
          next
        end
      end
      @opts['habtms'].each do |habtm|
        model = habtm.camelize 
        define_class = "class ::#{model} < ActiveRecord::Base; self.table_name = '#{habtm}'; end\n"
        p define_class
        @seed_rb << define_class
        eval define_class
        @models.push model
      end 
    end


    def loadModels
      puts "Searching in #{@opts['model_dir']} for models" if @opts['debug']
      Dir[Dir.pwd + '/' + @opts['model_dir']].sort.each do |f|
        puts "Processing file #{f}" if @opts['debug']
        # parse file name and path leading up to file name and assume the path is a module
        f =~ /models\/(.*).rb/
        # split path by /, camelize the constituents, and then reform as a formal class name
        parts = $1.split("/").map {|x| x.camelize}

        # Initialize nested model namespaces
        parts.clip.inject(Object) do |x, y|
          if x.const_defined?(y)
            x.const_get(y)
          else
            x.const_set(y, Module.new)
          end
        end

        model = parts.join("::")
        require f

        puts "Detected model #{model}" if @opts['debug']
        @models.push model if @opts['models'].include?(model) || @opts['models'].empty?
      end
    end

    def models
      @models
    end

    def last_record
      @last_record
    end

    def dumpAttribute(a_s,r,k,v)
      if v.is_a?(BigDecimal)
        v = v.to_s
      else
        v = attribute_for_inspect(r,k)
      end

      unless k == 'id' && !@opts['with_id']
        if (!(k == 'created_at' || k == 'updated_at') || @opts['timestamps'])
          a_s.push("#{k.to_sym.inspect} => #{v}")
        end
      end
    end

    def dumpModel(model)
      model.reset_callbacks(:initialize)
      @id_set_string = ''
      @last_record = []
      create_hash = ""
      options = ''
      rows = []
      arr = []
      arr = model.find(:all, @ar_options) unless @opts['no-data']
      return '' if arr.empty?

      arr.each_with_index { |r,i|

        # hack to avoid DEFAULT ReviewOfSystemsPolicy records from being written as they're already added by the bootstrapper
        next if r.class.name == 'ReviewOfSystemsPolicy' && r.id == 1
        next if r.class.name == 'ReviewOfSystemsPolicyReviewOfSystemsQuestionTie' && r.review_of_systems_policy_id == 1

        attr_s = [];
        r.attributes.each do |k,v|
          if ((model.attr_accessible[:default].include? k) || @opts['without_protection'] || @opts['with_id'])
            dumpAttribute(attr_s,r,k,v)
            @last_record.push k
          end
        end
        rows.push "#{@indent}{ " << attr_s.join(', ') << " }"
      }

      if @opts['without_protection']
        options = ', :without_protection => true '
      end

      if @opts['max']
        splited_rows = rows.each_slice(@opts['max']).to_a
        maxsarr = []
        splited_rows.each do |sr|
          maxsarr << "\n#{model}.#{@opts['create_method']}([\n" << sr.join(",\n") << "\n]#{options})\n"
        end
        maxsarr.join('')
      else
        "\n#{model}.#{@opts['create_method']}([\n" << rows.join(",\n") << "\n]#{options})\n"
      end

    end

    def dumpModels
      @models.each do |model|
          m = model.constantize
          if m.ancestors.include?(ActiveRecord::Base) && !m.abstract_class
            puts "Adding #{model} seeds." if @opts['verbose']

            if @opts['skip_callbacks']
              @seed_rb << "#{model}.reset_callbacks :validation\n"
              @seed_rb << "#{model}.reset_callbacks :validate\n"
              @seed_rb << "#{model}.reset_callbacks :save\n"
              @seed_rb << "#{model}.reset_callbacks :create\n"
              puts "Callbacks are disabled." if @opts['verbose']
            end

            @seed_rb << dumpModel(m) << "\n\n"
          else
            puts "Skipping non-ActiveRecord model #{model}..." if @opts['verbose']
          end
      end
    end

    def writeFile
      File.open(@opts['file'], (@opts['append'] ? "a" : "w")) { |f|
        f << "# encoding: utf-8\n"
        f << "# Autogenerated by the db:seed:dump task\n# Do not hesitate to tweak this to your needs\n" unless @opts['append']

        f << <<-EOT.gsub(/^        /, '')

        DAYS_SINCE_DUMP = (Time.now.utc.to_date - Date.parse('#{Time.now.utc.strftime('%Y-%m-%d')}')).to_i
        puts "Dates will be shifted forward by \#{DAYS_SINCE_DUMP} days"

        def shift_date(date, avoid_weekends)
          shifted = date + DAYS_SINCE_DUMP
          if avoid_weekends
            shifted += 2 if shifted.saturday?
            shifted += 1 if shifted.sunday?
          end
          shifted
        end

        def shift_time(time, avoid_weekends)
          shifted = time + (DAYS_SINCE_DUMP * 1.day)
          if avoid_weekends
            shifted += 2.day if shifted.saturday?
            shifted += 1.day if shifted.sunday?
          end
          shifted.beginning_of_day + 23.hours
        end

        def shift_month(date, avoid_weekends)
          shifted = (date + DAYS_SINCE_DUMP).beginning_of_month
          if avoid_weekends
            shifted += 2.day if shifted.saturday?
            shifted += 1.day if shifted.sunday?
          end
          shifted
        end

        EOT

        f << "ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=0')\n"
        f << "#{@seed_rb}"
        f << "ActiveRecord::Base.connection.execute('SET FOREIGN_KEY_CHECKS=1')"
      }
    end

    #override the rails version of this function to NOT truncate strings
    def attribute_for_inspect(r,k)
      value = r.attributes[k]

      # relative shifting of time/date values may cause dates to fall on weekends resulting 
      # in unrealistic data - set this flag to avoid weekends
      avoid_weekends = true
      include_weekends_classes = %w{
        Event TreatmentEvent TrackerSignallValue VisitPreparation 
        Clinic::InformationPrescriptionContentClinicPatientLinkTie 
        ChronicCare::PatientMonthlyTimeReport
      }

      shift_month_classes = %w{ ChronicCare::PatientMonthlyTimeReport }

      if shift_month_classes.include?(r.class.name) && k == "month"
        date_shift_method = "shift_month"
      else
        date_shift_method = "shift_date"
      end

      if include_weekends_classes.include?(r.class.name) || r.class.name =~ /CareManagement/
        avoid_weekends = false
      end

      if value.is_a?(String) && value.length > 50
        "#{value}".inspect
      elsif value.is_a?(Date)
        "#{date_shift_method}(Date.parse('#{value.strftime('%Y-%m-%d')}'), #{avoid_weekends})"
      elsif value.is_a?(Time)
        "shift_time(Time.parse('#{value.strftime('%Y-%m-%d %H:%M:%S %z')}').utc, #{avoid_weekends})"
      else
        value.inspect
      end
    end

    def setSearchPath(path, append_public=true)
        path_parts = [path.to_s, ('public' if append_public)].compact
        ActiveRecord::Base.connection.schema_search_path = path_parts.join(',')
    end

    def run(env)

      setup env

      puts "Protection is disabled." if @opts['verbose'] && @opts['without_protection']

      setSearchPath @opts['schema'] if @opts['schema']

      initializeModels

      puts "Appending seeds to #{@opts['file']}." if @opts['append']
      dumpModels

      puts "Writing #{@opts['file']}."
      writeFile

      puts "Done."
    end
  end
end
