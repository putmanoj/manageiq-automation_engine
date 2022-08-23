module MiqAeMethodService
  class MiqAeServiceCloudVolume < MiqAeServiceModelBase
    require_relative "mixins/miq_ae_service_ems_operations_mixin"
    include MiqAeServiceEmsOperationsMixin

    expose :create_volume_snapshot, :override_return => nil
    expose :attach_volume,          :override_return => nil
    expose :detach_volume,          :override_return => nil
  end

  def self.create_volume_task(ems, options = {})
    ext_management_system = ExtManagementSystem.find(ems)
    CloudVolume.create_volume_queue('admin', ext_management_system, options)
  end
end
