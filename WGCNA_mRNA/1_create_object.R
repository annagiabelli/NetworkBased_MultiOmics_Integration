## FIRST PART OF WGCNA: create WGCNA object to obtain modules

#---
#! NOTE: since some calculations are computational heavy, it would be better to run this R file with the bash script
#!       "1_create_object_script.sh" on work nodes                                              
#---

# # install libraries
# BiocManager::install("impute") # in order to install WGCNA
# BiocManager::install("WGCNA") # in order to install WGCNA
# install.packages('flashClust')
# BiocManager::install("rversions") # in order to install devtools
# install.packages("xml2") # in order to install devtools
# install.packages("devtools")
# BiocManager::install('devtools')
# devtools::install_github("kevinblighe/CorLevelPlot")

# load libraries
library(devtools)
library(WGCNA)
library(flashClust)
library(curl)
library(ggplot2)
library(DESeq2)
library(tidyverse)
library(gridExtra)
library(CorLevelPlot)
library(pheatmap)


## 0. Definition of input/output paths ----------------------------------------------------------------------
initial_path <- file.path("WGCNA_mRNA/data")
out_path <- file.path("WGCNA_mRNA/output")
plot_path <- file.path("WGCNA_mRNA/plot")

## 1. Get data from nf-core piepeline ----------------------------------------------------------------------
# Load txt file with the number of reads
file = file.path(initial_path, 'salmon.merged.gene_counts.tsv')
counts_data <- read.delim(file, sep = "\t", header = TRUE)

dim(counts_data)
head(counts_data)

# check that gene_id and gene_name are always the same
all(counts_data$gene_id==counts_data$gene_name)
# Set row names
rownames(counts_data) <- counts_data$gene_id
counts_data <- counts_data[ , !names(counts_data) %in% c("gene_id", "gene_name")]
head(counts_data)

# Round and convert numeric columns to integer (to create a dds object later)
counts_data[] <- lapply(counts_data, function(x) {
  if (is.numeric(x)) {
    as.integer(round(x))
  } else {
    x 
  }
})
sapply(counts_data, is.integer)
head(counts_data)
dim(counts_data)


## 2A. Detect & exclude outliers ----------------------------------------------------------------------
gsg <- goodSamplesGenes(t(counts_data))
summary(gsg)
gsg$allOK

table(gsg$goodGenes)
table(gsg$goodSamples)

# exclude genes
data <- counts_data[gsg$goodGenes == TRUE, ]

# check again samples for outliers with another method (clustering)
htree <- hclust(dist(t(data)), method='average')
# plot to see if there are outliers
pdf(file.path(plot_path, '1_htree_out_detect.pdf'))
plot(htree)
dev.off()

# check again samples for outliers with another method (pca)
pca <- prcomp(t(data))
pca.dat <- pca$x
pca.var <- pca$sdev^2
pca.var.percent <- round(pca.var/sum(pca.var)*100, digits = 2)
pca.dat <- as.data.frame(pca.dat)
# plot to see if there are outliers
pdf(file.path(plot_path, '1_pcaplot_out_detect.pdf'))
ggplot(pca.dat, aes(PC1, PC2)) +
  geom_point() +
  geom_text(label = rownames(pca.dat)) +
  labs(x = paste0('PC1: ', pca.var.percent[1], ' %'),
       y = paste0('PC2: ', pca.var.percent[2], ' %'))
dev.off()


# 2B. Exclude genes with low variance ----------------------------------------------------------------------
geneVariance <- apply(data, 1, var)
threshold <- quantile(geneVariance, 0.30)  
data_filtered <- data[geneVariance > threshold, ]

dim(data)
dim(data_filtered)


# 3. Normalization ----------------------------------------------------------------------
# create a deseq2 dataset
colnames(data_filtered)
# Create colData
sampletype <- as.factor(c(rep('CTR',6), rep('GEMTAX', 5), rep('SIM',6), rep('VPA', 6), 
rep('VPA_SIM', 5), rep('VS_GEMTAX', 6)))
colData <- data.frame(sampletype, row.names = colnames(data_filtered))

# making the rownames and column names identical
all(rownames(colData) %in% colnames(data_filtered))
all(rownames(colData) == colnames(data_filtered))

# create dds
dds <- DESeqDataSetFromMatrix(countData = data_filtered,
                              colData = colData,
                              design = ~ 1) # not spcifying model

dim(data_filtered)
## remove all genes with counts < 30 in more than 75% of samples (34*0.75=9)
## suggested by WGCNA on RNAseq FAQ
dds75 <- dds[rowSums(counts(dds) >= 30) >= 26,]
nrow(dds75)

# perform variance stabilization
dds_norm <- vst(dds75)

# get normalized counts
norm.counts <- assay(dds_norm) %>% 
  t()
# save for later
saveRDS(norm.counts, file = file.path(out_path, "norm_counts.rds"))


# 4. Network Construction  ---------------------------------------------------
# Choose a set of soft-thresholding powers to then select the best
power <- c(c(1:10), seq(from = 12, to = 30, by = 2))
# Call the network topology analysis function
sft <- pickSoftThreshold(norm.counts,
                  powerVector = power,
                  networkType = "signed",
                  verbose = 5)

sft.data <- sft$fitIndices

# visualization to pick power
pdf(file.path(plot_path, '1_rsqd_meank_threshold.pdf'))
a1 <- ggplot(sft.data, aes(Power, SFT.R.sq, label = Power)) +
  geom_point() +
  geom_text(nudge_y = 0.1) +
  geom_hline(yintercept = 0.8, color = 'red') +
  labs(x = 'Power', y = 'Scale free topology model fit, signed R^2') +
  theme_classic()
a2 <- ggplot(sft.data, aes(Power, mean.k., label = Power)) +
  geom_point() +
  geom_text(nudge_y = 0.1) +
  geom_hline(yintercept = 100, color = 'red') +
  labs(x = 'Power', y = 'Mean Connectivity') +
  theme_classic()
grid.arrange(a1, a2, nrow = 2)
dev.off()

# based on the author's table we choose 14, the plot shows we never are above 0.8 as suggested
soft_power <- 14

# convert matrix to numeric
norm.counts[] <- sapply(norm.counts, as.numeric)

# compute adjacency
adjacency <- adjacency(norm.counts, 
                       type = "signed",
                       power = soft_power)
str(adjacency)
# save for later
saveRDS(adjacency, file = file.path(out_path, "adjacency.rds"))

# we need to set it before running blockwiseModules()
temp_cor <- cor
cor <- WGCNA::cor

# run # create modules
bwnet <- blockwiseModules(norm.counts,
                 maxBlockSize = nrow(dds75)+10,
                 TOMType = "signed",
                 networkType = "signed",
                 saveTOMs = FALSE,
                 power = soft_power,
                 mergeCutHeight = 0.25,
                 numericLabels = FALSE,
                 randomSeed = 1234,
                 verbose = 3)

cor <- temp_cor

# save output
saveRDS(bwnet, file = file.path(out_path, "bwnet.rds"))
