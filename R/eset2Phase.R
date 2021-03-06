#' eset2Phase
#'
#' @param eset 
#' @param low.prob 
#' @param parallel Use parallel processing? Default: FALSE
#'
#' @return
#' @export
#'
#' @examples
eset2Phase <- function(eset, low.prob=0.99, parallel = FALSE){  ## takes eSet as input
    Y <- round(exprs(eset))
    #################################################
    ## ## initial estimate of prob(X\in bg)
    ##################################################
    Cell0=colMeans(Y==0) # each cell has this percentage 0
    plan(multiprocess)
    if (isTRUE(parallel)){
        par1=future_apply(Y,2,function(yy) {
            yy=yy[yy<=15]
            RobustPoi0(yy)
        })   
    } else {
        par1=apply(Y,2,function(yy) {
            yy=yy[yy<=15]
            RobustPoi0(yy)
        })
    }
    pi0.hat=Cell0/(par1[1,]+(1-par1[1,])*dpois(0,par1[2,]))
    if (any((pi0.hat > 1))) {warning("Zero proportion is greater than estimation.")}
    pi0.hat <- pmin(pi0.hat, 1)
    prob0=pi0.hat*par1[1,]+ pi0.hat*(1-par1[1,])*dpois(0,par1[2,]) ## ZIP prob at 0
    ############################################
    ## First round 
    ###########################################
    ## get the 1-low.prob quantile of ZIP
    x0=qpois(pmax(1-(1-low.prob)/(1-par1[1,]),0),par1[2,])
    Z= sweep(Y,2,x0)>0 # indicate if a gene is > bg 
    L=colSums(Y*Z)/1e6 # so far it is like simple total..
    
    mu.g1=log2(rowSums(Z*Y)/rowSums(sweep(Z,2,L,FUN="*")))
    mu.g1[is.na(mu.g1)]=0 ## if allZ is 0, it gets NA, 
    ### but we should shrink mu.g1 as well since some mu.g1 is estimated by only a few observations
    ## leave it here for now.
    n.g1=rowSums(Z)
    y1=log2(sweep(Y,2,L,FUN="/")+1) #like CPM**
    s.g1=sqrt(rowSums(Z*sweep(y1,1,mu.g1)^2)/(n.g1-1)) ## CPM type of SD
    mu.g2 = shrink.mu(mu.g1,s.g1,n.g1)
    ###############################################
    ## get sd.g
    ############################################
    res.g1=log2(sweep(Y,2,L,FUN="/")+1)-mu.g1
    ## mad of those res.g1 that are associated with Z==1
    tmp=array(0,dim=c(dim(res.g1),2))
    tmp[,,1]=res.g1;tmp[,,2]=Z
    if (isTRUE(parallel)){
        sd.g1=future_apply(tmp,1,function(xx) my.mad(xx[xx[,2]==1,1]))
    } else {
        sd.g1=apply(tmp,1,function(xx) my.mad(xx[xx[,2]==1,1]))
    }
    sd.g1[is.na(sd.g1)]=0## if all bg, there's no info about fg sd
    ## add a shrinkage for sd.g1 
    sd.prior=squeezeVar(sd.g1^2,n.g1-1)
    sd.g2=sqrt(sd.prior$var.post)
    ####################################### ########
    #####  gene specific bg. Z_gi
    #######################
    den.fg = den.bg = NA*Y
    
    for (i in 1:ncol(Y)){
            den.bg[,i]=dZinf.pois(Y[,i], par1[1,i], par1[2,i])
            den.fg[,i]=dLNP2(x=Y[,i], mu=mu.g1, sigma=sd.g2, l=L[i])
    }
    Z.fg=sweep(den.fg,2,1-pi0.hat,FUN="*")
    Z.bg=sweep(den.bg,2,pi0.hat,FUN="*")
    post.Z=Z.fg/(Z.fg+Z.bg)
    post.Z[is.na(post.Z)] <- 1
    
    ### if I shrink mu.g
    den.fg2 = NA*Y
    for (i in 1:ncol(Y)){
            den.fg2[,i]= dLNP2(x=Y[,i], mu=mu.g2, sigma=sd.g2, l=L[i])
    }
    Z.fg2=sweep(den.fg2,2,1-pi0.hat,FUN="*")
    post.Z2=Z.fg2/(Z.fg2+Z.bg)
    post.Z2[is.na(post.Z2)] <- 1
    ##################################################
    ## compute offsets
    ##################################################
    Offset = Y*0
    Ylim=range(log2(1+Y)-mu.g1)
    Xlim=range(mu.g1)
    
    for (i in 1:ncol(Y)){
        tmp.y=log2(1+Y[,i])-mu.g2
        subset= post.Z2[,i] > .99
        lm1 <- loess(tmp.y~mu.g1,
                     weights=post.Z2[,i]*mu.g2,
                     subset=subset,
                     degree=1,
                     span=.3)
        Offset[subset,i]=lm1$fitted
    }
    ##################################################
    ## assemble the estimators into sc2pSet object
    ##################################################
    ## add mu and sd to feature data
    fdata <- fData(eset)
    fdata2 <- as.data.frame(cbind(fdata, mu.g2, sd.g2))
    colnames(fdata2) <- c(colnames(fdata), "mean", "sd")
    fvar <- rbind(fvarMetadata(eset), 
                  "mean"="shrinkage estimated foreground mean",
                  "sd"="shrinkage estimated foreground standard deviation")
    featureData <- new("AnnotatedDataFrame", 
                       data=fdata2,
                       varMetadata=fvar)
    ## add lambda and p0 to phenoData
    pdata <- pData(eset)
    pdata2 <- as.data.frame(cbind(pdata, par1[1,], par1[2,], L))
    colnames(pdata2) <- c(colnames(pdata), "p0", "lambda", "L")
    pvar <-rbind(varMetadata(eset), "p0"="proportion of zero inflation",
                 "lambda"="mean of background poisson",
                 "L"="foreground library size")
    phenoData <- new("AnnotatedDataFrame", data=pdata2, varMetadata=pvar)
    
    out <- new("sc2pSet", exprs=Y, Z=post.Z2, Offset=Offset,
               phenoData=phenoData,
               featureData=featureData,
               experimentData=experimentData(eset),
               annotation=annotation(eset))
    out
}

