# encoding: utf-8
require 'openssl'
require 'active_support'
require 'active_support/core_ext'
require "httparty"
require 'nokogiri'
require 'digest/sha1'

module Cmbchina

  URI = {
    #支付网关
    gateway: {
      api:  'https://payment.ebank.cmbchina.com/NetPayment/BaseHttp.dll',
      live: 'https://netpay.cmbchina.com/netpayment/BaseHttp.dll?PrePayC2',
      test: 'https://netpay.cmbchina.com/netpayment/BaseHttp.dll?TestPrePayC2'
    }
  }

  @@gateway_url = URI[:gateway][:live]


  class << self
    attr_accessor :branch_id #开户分行号
    attr_accessor :co_no  #商户号
    attr_accessor :public_key #招行官方公钥(从der版本转换为pem版本)
    attr_accessor :secret #商户秘钥
    attr_accessor :password #登录密码
    attr_accessor :env

    def initialize
      @env = :test
    end

    def config(options)
      options.each do |key, value|
        send "#{key}=", value
      end
    end

    def url
      URI[:gateway][env]
    end

    def api_url
      URI[:gateway][:api]
    end
    
  end

  module Sign
    class << self
      #返回消息的明文
      def plain_text(param_string)
        params = Rack::Utils.parse_nested_query(param_string)
        params.delete("Signature")
        Rack::Utils.build_query(params)
      end

      #返回消息的数字签名
      def signature(param_string)
        sign = Rack::Utils.parse_nested_query(param_string).delete("Signature")
        sign.split('|').map{|ascii_code| ascii_code.to_i.chr }.join('')
      end

      #验证数字签名
      def verify(param_string)
        pub = OpenSSL::PKey::RSA.new(Cmbchina.public_key)
        pub.verify('sha1', signature(param_string), plain_text(param_string))
      end
    end
  end

  module Api
    include HTTParty
    class << self
      def post_command(command, data = {})
        data = data.merge({ co_no: Cmbchina.co_no })
        data = data.inject({}) do | r, (k, v) |
          r[k.to_s.camelize()] = v
          r
        end

        data['BranchID'] = Cmbchina.branch_id
        url = "#{Cmbchina.api_url}?#{command}"

        #puts ""
        #puts "***" * 10
        #puts "#{url}&#{data.to_query}"
        respone = post(url, { body: data })
        #p respone
        #puts "***" * 10
        #puts ""

        respone.body.encode('utf-8', 'gb2312').split("\n")
      end

      def get_session
        Cmbchina::SessionObject.new(post_command('DirectEnter'))
      end

      def login(pwd = nil)
        session = get_session
        session.login(pwd)
        session
      end

    end
  end

  class SessionObject
    include HTTParty

    attr_accessor :client_no #会话号码
    attr_accessor :serial_no  #序列号

    def initialize(message = nil)
      if message.present? and message[0]=='Y'
        @client_no = message[1]
        @serial_no = message[2]
      else
        raise "could not connect the cmbchina api url"
      end
    end

    def login(pwd = nil)
      pwd = Cmbchina.password unless pwd
      message = post_command('DirectLogonC', { pwd: pwd })

      if message.present? and message[0]=='Y'
        @client_no = message[1] if message[1]
        @serial_no = message[2] if message[2]
      else
        raise "login fails"
      end
      message
    end

    def logout
      post_command('DirectExit')
    end

    def query_settled_orders(options)
      message_array = post_command('DirectQuerySettledOrderByPage', query_order_options(options))
      explan_order_list( message_array )
    end

    def query_refund_orders(options)
      message_array = post_command('DirectQueryRefundByDate', query_order_options(options))
      explan_order_list( message_array )
    end

    def get_order( bill_no, bill_date )
      options = {
        version: 1,
        co_no: Cmbchina.co_no,
        date: bill_date,
        bill_no: bill_no
      }
      message_order = post_command('DirectQuerySingleOrder', options)
      if message_order.shift == 'Y' and message_order.size > 2
        message_order.push bill_no
        Cmbchina::Order.new( message_order )
      end
    end

    def refund( options )
      refund_options = {
        date: options[:date],
        bill_no: options[:bill_no],
        amount: options[:amount],
        desc: options[:desc],
        vcode: get_vcode(options)
      }
      post_command('DirectRefund', refund_options )
    end

    private
    def explan_order_list(message_array)
      success = message_array.shift
      pos = message_array.shift
      has_next = message_array.shift
      orders = []
      if success =='Y' and has_next =='N' and message_array.size > 2
        message_orders = message_array.in_groups_of(9)
        orders = message_orders.map do | message_order |
          data =  [ message_order[0], message_order[1], message_order[4], message_order[2], message_array[5], message_array[6], nil, message_array[7], message_array[8], message_array[3] ] 
          Cmbchina::Order.new( data )
        end
      end
      { success?: (success =='Y'), pos: pos, has_next?: (has_next =='Y'), orders: orders }
    end

    def post_command(command, data = {})
      data = data.merge({ client_no: self.client_no, serial_no: self.serial_no })
      Cmbchina::Api.post_command(command, data)
    end

    def query_order_options(options)
      params = {
        begin_date: options[:begin_date],
        end_date: options[:end_date],
        type: 0,
        version: 1,
        count: options[:count] || 200,
        pos: options[:pos] || 0
      }
      params
    end
    
    def get_vcode(options)
      code = "#{self.serial_no}#{Cmbchina.secret}#{self.client_no}#{Cmbchina.branch_id}#{Cmbchina.co_no}#{options[:date]}#{options[:bill_no]}#{options[:amount]}#{options[:desc]}"
      Digest::SHA1.hexdigest(code)
    end

  end

  class Message
    include HTTParty

    attr_accessor :branch_id                #分行号
    attr_accessor :co_no                    #商户号
    attr_accessor :bill_no                  #订单号
    attr_accessor :date                     #订单下单日期
    attr_accessor :bank_serial_no           #银行流水号
    attr_accessor :bank_date                #银行主机交易日期
    attr_accessor :succeed                  #消息成功失败,成功为'Y',失败为'N'
    attr_accessor :amount                   #实际支付金额
    attr_accessor :msg                      #银行通知用户支付结构消息
    attr_accessor :signature                #通知命令签名
    attr_accessor :merchant_para            #商户自定义传递参数
    attr_accessor :merchant_url             #商户回调url

    attr_reader   :query_string             #原始的query_string

    def initialize(query_string)
      query_string = Rack::Utils.build_query(query_string) if query_string.is_a? Hash
      @query_string = query_string
      params = Rack::Utils.parse_nested_query(query_string)

      # 银行通知用户的支付结果消息。信息的前38个字符格式为：4位分行号＋6位商户号＋8位银行接受交易的日期＋20位银行流水号；可以利用交易日期＋银行流水号对该定单进行结帐处理；
      @bill_no = params["BillNo"]
      @date = params["Date"]
      @succeed = params["Succeed"]
      @amount = params["Amount"].to_f
      @msg = params["Msg"]
      @signature = params["Signature"]
      @merchant_para = params["MerchantPara"]
      @merchant_url = params["MerchantUrl"]

      msg = params["Msg"][0..37]
      @branch_id = msg[0..3]
      @co_no = msg[4..9]
      @bank_date = msg[10..17]
      @bank_serial_no = msg[18..37]
    end

    def verify?
      Cmbchina::Sign.verify(query_string)
    end

    def succeed?
      succeed == 'Y'
    end

    def order_uuid
      merchant_para
    end

    def trade_no
      bill_no
    end

    def amount_cents
      (amount * 100).to_i
    end

    def payment_date
      Date.strptime(bank_date, "%Y%m%d")
    end

  end

  class Order

    attr_reader :bill_no
    attr_reader :order_date
    attr_reader :bill_date
    attr_reader :amount
    attr_reader :fee
    attr_reader :merchant_para
    attr_reader :bank_date
    attr_reader :bank_time

    def initialize( message_array )
      @order_date, @bill_date, @bill_status_code, @amount, @card_type_code, @fee, @merchant_para, @bank_date, @bank_time, @bill_no = message_array
    end

    def trade_no
      @bill_no
    end

    def bill_status
      status_map = { '0'=>'已结账', '1'=>'已撤销', '2'=>'部分结账', '3'=>'退款记录', '5'=>'无效状态', '6'=>'未知状态' }
      status_map[@bill_status_code]
    end

    def card_type
      type_map = { '02'=>'招行一卡通', '03'=>'招行信用卡', '04'=>'其他银行卡' }
      type_map[@card_type_code]
    end

  end

  module Service

    #根据订单信息生成跳转的支付链接，option为订单相关信息hash
    def self.generate_link(options)
      query_options = {
        'BranchID'  => options[:branch_id] || Cmbchina.branch_id,
        'CoNo'      => options[:co_no] || Cmbchina.co_no,
        'Amount'    => options[:amount],
        'BillNo'    => options[:bill_no],
        'Date'      => options[:date],
        'MerchantUrl'    => options[:merchant_url],
        'MerchantPara'   => options[:merchant_para],
        'MerchantReturnURL'   => options[:merchant_return_url]
      }
      { url: "#{Cmbchina.url}", options: query_options, url_and_options: "#{Cmbchina.url}?#{query_options.to_query}" }
    end

    #处理支付成功后返回的信息
    def self.get_pay_message(query_string)
      Cmbchina::Message.new query_string
    end
  end
  
end
