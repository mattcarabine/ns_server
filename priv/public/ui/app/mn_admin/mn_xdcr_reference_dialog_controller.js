import _ from "/ui/web_modules/lodash.js";

export default mnXDCRReferenceDialogController;

function mnXDCRReferenceDialogController($uibModalInstance, mnPromiseHelper, mnXDCRService, reference, mnPoolDefault) {
  var vm = this;
  vm.isNew = !reference;
  vm.mnPoolDefault = mnPoolDefault.latestValue();
  vm.cluster = !vm.isNew ? _.clone(reference) : {
    username: 'Administrator'
  };
  vm.createClusterReference = createClusterReference;

  if (!vm.cluster.encryptionType && vm.mnPoolDefault.value.isEnterprise) {
    vm.cluster.encryptionType = "half";
  }

  function createClusterReference() {
    var promise = mnXDCRService.saveClusterReference(vm.cluster, reference && reference.name);
    mnPromiseHelper(vm, promise, $uibModalInstance)
      .showGlobalSpinner()
      .catchErrors()
      .closeOnSuccess()
      .broadcast("reloadXdcrPoller")
      .showGlobalSuccess("Cluster reference saved successfully!");
  };
}
