# Fresh corrected default DLL profile only; no old registration cases or models.
args <- commandArgs(TRUE)
stopifnot(length(args)==2L, !"relm" %in% names(getLoadedDLLs()))
path <- normalizePath(args[[1]],mustWork=TRUE)
dll <- dyn.load(path,local=TRUE,now=TRUE)
sym <- getNativeSymbolInfo("wrap__rebirth_projection_allocation_profile",PACKAGE=dll)
stopifnot(identical(sym$numParameters,0L),identical(normalizePath(sym$dll[["path"]]),path))
profile <- .Call(sym)
expected_names <- c("version","direction_arc_header_bytes","plan_arc_bytes","site_bytes","runtime_bytes","probe_state_bytes","model_owner_bytes","derive_frame_bytes","callback_frame_bytes","probe_frame_bytes","residual_probe_fixed_bytes","ffi_fixed_bytes","adapter_fixed_bytes","error_format_bytes","metadata_owner_bytes","slot_bytes","proof_bytes","projection_info_bytes","cpp_access_frame_bytes","cpp_name_frame_bytes","ffi_command_bytes","ffi_response_bytes","ffi_registry_bytes","ffi_handle_tag_bytes","layout_checksum","max_sites","max_width")
expected_fixed <- setNames(c(2,16,48,32,5072,56,912,11959,429,153,522,256,150,0,64,152,128,77,64,744,1512,15,423797551137116,32,65536),c("version","direction_arc_header_bytes","plan_arc_bytes","site_bytes","runtime_bytes","probe_state_bytes","model_owner_bytes","derive_frame_bytes","callback_frame_bytes","probe_frame_bytes","residual_probe_fixed_bytes","adapter_fixed_bytes","error_format_bytes","metadata_owner_bytes","slot_bytes","proof_bytes","projection_info_bytes","cpp_access_frame_bytes","cpp_name_frame_bytes","ffi_command_bytes","ffi_response_bytes","ffi_handle_tag_bytes","layout_checksum","max_sites","max_width"))
stopifnot(is.list(profile),identical(names(profile),expected_names))
for(n in names(profile)) stopifnot(typeof(profile[[n]])=="double",length(profile[[n]])==1L,is.finite(profile[[n]]),profile[[n]]>=0,profile[[n]]==floor(profile[[n]]))
for(n in names(expected_fixed)) stopifnot(identical(profile[[n]],as.double(expected_fixed[[n]])))
stopifnot(profile$ffi_registry_bytes >= 32, (profile$ffi_registry_bytes-32) %% 16 == 0,
 profile$ffi_fixed_bytes == profile$ffi_response_bytes + profile$ffi_registry_bytes + 160)
write.csv(data.frame(field=names(profile),value=unlist(profile,use.names=FALSE)),file.path(args[[2]],"compiled-profile.csv"),row.names=FALSE)
saveRDS(profile,file.path(args[[2]],"compiled-profile.rds"))
cat("F6E_REVIEW_FIX_PROFILE fields=27 models=0 inference=0 fixed_profile_preserved=1
")
