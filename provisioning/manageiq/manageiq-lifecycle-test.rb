#!/usr/bin/env ruby

require 'rest-client'
require 'json'
require 'base64'

CF_ADDR = ARGV[0]
CF_CRED = ARGV[1] # username:password
CATALOG_ID = ARGV[2]
MAX_RETIRES = 20 #wait 20 minutes for the service request to complete

def call_api(url, method, content_type, accept, payload={})
  puts "calling api at #{url}"
  params = {
    :method => method,
    :url => url,
    :verify_ssl => false,
    :headers => {
      :authorization  => "Basic #{Base64.strict_encode64("#{CF_CRED}")}",
      :content_type => content_type,
      :accept => accept
      }
    }

  # If there's a payload, convert it to json.
  unless payload.empty?
    if content_type == :json
      params[:payload] = JSON.generate(payload)
    else
      exit 1
    end
  end

  begin
    response = RestClient::Request.new(params).execute
  rescue => error
    exit 1
  end

  if accept == :json
    response_hash_array = JSON.parse(response)
    return response_hash_array
  elsif accept == "text/html"
    return response
  else
    exit 1
  end
end

# This method will initiate a service provision in CloudForms through the api
# It will return the service request id
def initiate_service_provision(base_url, catalog_id)
  url = "#{base_url}" + "/service_templates/#{catalog_id}"

  payload = {
    :action => "order"
  }

  response = call_api(url, :post, :json, :json, payload)
  puts "#{response.inspect}"

  service_request_id = response['id']

  return service_request_id
end

def get_request_task_url(base_url, service_request_id)
  url = "#{base_url}" + "/service_requests/#{service_request_id}/request_tasks?filter[]=request_type=template"

  response = call_api(url, :get, :json, :json)
  puts "#{response.inspect}"

  request_task_url = response['resources'][0]['href']

  return request_task_url
end

def get_vm_id(request_task_url)
  url = request_task_url

  response = call_api(url, :get, :json, :json)
  puts "#{response.inspect}"

  vm_id = response['destination_id']

  return vm_id
end

def get_service_request_info(base_url, service_request_id)
  url = "#{base_url}" + "/service_requests/#{service_request_id}"

  response = call_api(url, :get, :json, :json)
  puts "#{response.inspect}"

  return response
end

def retire_vm(base_url, vm_id)
  url = "#{base_url}" + "/vms/#{vm_id}"

  payload = {
    :action => "retire"
  }

  response = call_api(url, :post, :json, :json, payload)
  puts "#{response.inspect}"

  return response
end

def get_vm_info(base_url, vm_id)
  url = "#{base_url}" + "/vms/#{vm_id}"

  response = call_api(url, :get, :json, :json)
  puts "#{response.inspect}"

  return response
end

#--- Begin main method---#
begin
  base_url = "https://#{CF_ADDR}/api"

  puts "calling initiate_service_provision"
  # Initiate the service provisioning process
  service_request_id = initiate_service_provision(base_url, CATALOG_ID)

  # Wait until service request is complete
  puts "waiting for service request to complete"
  while get_service_request_info(base_url, service_request_id)['request_state'] != "finished"
    puts "waiting for service request to complete. sleeping for 20 seconds"
    sleep(20)
  end

  puts "checking the status of the request"
  if get_service_request_info(base_url, service_request_id)['status'] == "Error"
    puts "the service request failed"
    exit 1
  else
    puts "the request completed successfully"
  end

  puts "calling get_request_task_url"
  # We need the vm_id so that we can reference it for retirement
  request_task_url = get_request_task_url(base_url, service_request_id)

  puts "calling get_vm_id"
  vm_id = get_vm_id(request_task_url)
  puts "#{vm_id.inspect}"

  puts "retiring the VM"
  retire_vm(base_url, vm_id)

  # Wait until retirement has completed
  puts "waiting for retirement to complete"
  vm_retirement_state = get_vm_info(base_url, vm_id)['retirement_state']
  while vm_retirement_state != "error" && vm_retirement_state != "retired"
    sleep(20)
    vm_retirement_state = get_vm_info(base_url, vm_id)['retirement_state']
    puts "waiting for retirement to complete. sleeping for 20 seconds."
  end

  if vm_retirement_state == "error"
    puts "retirement failed"
    exit 1
  else
    puts "retirement successful"
  end
rescue => err
  puts "#{err.inspect}"
  exit 1
end
